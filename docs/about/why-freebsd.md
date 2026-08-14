# Why FreeBSD

SatL is not a Linux container engine ported to FreeBSD. Most of what a
container engine has to build on Linux, FreeBSD already has as a first-class
kernel subsystem — and the pieces it does not have are missing in ways that
change the product, not just the implementation.

## The substrate

| What a container needs | FreeBSD gives | How SatL uses it |
| --- | --- | --- |
| Isolation | `jail(8)` | One jail per task, with `vnet` for its own network stack |
| A layered filesystem | ZFS | A layer *is* a dataset; applying a layer is snapshot + clone; a container's writable layer is a clone of the image's top snapshot |
| Networking | `if_bridge(4)`, `epair(4)`, `vnet` | One bridge per network, one epair per task, the `b` end moved into the jail's VNET |
| The data path | `pf(4)` | NAT for egress and `rdr` for published ports, in SatL's own anchors |
| Resource limits | `rctl(8)` / racct | One rule per container, added and removed with it |
| Cross-node networking | `if_vxlan(4)` | One VNI per overlay network, unicast, with a Raft-distributed forwarding table |

**ZFS is not one storage driver among several.** `satld` refuses to start
without its root dataset, and the reason is that the whole layer store is
expressed in ZFS primitives rather than emulated on top of a filesystem that
does not have them. There is no overlayfs to configure, no graph driver to
choose and nothing to tune. `zfs list -r zroot/satl` is the honest inventory of
what the engine is holding, and `zfs destroy` is what reclaims it.

**pf is the data path, not a firewall bolted on.** SatL generates the complete
contents of its `satl/nat` and `satl/rdr` anchors on every change and reloads
them wholesale; it never edits a rule and never touches anything outside
`satl/*`. An operator declares three anchor lines in `/etc/pf.conf` once, and
from then on the anchors are SatL's to own. You can read exactly what a node is
doing at any moment with `pfctl -a satl/rdr -s nat`.

**Jails are cheap and real.** A VNET jail gets its own routing table, its own
interfaces and its own network stack; it is not a namespace trick. That has a
diagnostic consequence worth internalising early: TCP and inner-IP counters
belong to the *jail's* stack, while tunnel and fragmentation counters belong to
the *host's*. Reading the wrong one is the fastest route to a confident wrong
conclusion.

## The four things FreeBSD does not have

Each of these costs something visible. None of them is a bug, and none is
going to be fixed by trying harder.

### No cgroups — rctl instead, and `--memory` kills

Resource limits go through `rctl(8)`, which needs resource accounting compiled
in *and* switched on. Accounting is a **boot-time tunable**: `kern.racct.enable=1`
in `/boot/loader.conf` and a reboot. `satld` probes it at startup and says which
mode it is in, and with accounting off it degrades rather than refusing to run —
`--memory` and `--cpus` are accepted, recorded in the task's status message, and
**not enforced**.

What the flags do when they *are* enforced is not what a Linux user expects:

| Flag | Rule installed | Behaviour |
| --- | --- | --- |
| `--memory` | `jail:<id>:memoryuse:sigkill=<bytes>` | The process is **killed** when the jail's resident set crosses the cap. This is the closest FreeBSD equivalent of a cgroup OOM kill; there is no throttling and no reclaim. |
| `--cpus` | `jail:<id>:pcpu:deny=<percent>` | The scheduler **throttles** the jail toward the cap. Accounting is a decaying average, so the cap is approached rather than imposed instantly. |

`memoryuse:deny` would look more like a cgroup limit and is silently useless:
RSS is not a deniable resource in the kernel, and `rctl` accepts the rule
anyway — a 64 MB `deny` cap was measured allocating 200 MB without complaint.
So a SatL memory limit is a kill, and a container that reaches it dies.

### No PID namespace — no `pid` mode, and no in-jail process illusions

A jail restricts *visibility* of processes, but there is no separate PID
namespace: the process inside the jail does not see itself as PID 1 in a
namespace of its own, and there is no way to share or join another container's
PID view. `PidMode`, `IpcMode`, `UTSMode` and `UsernsMode` are therefore
rejected with a 400 rather than accepted and ignored. Images that expect to be
PID 1 in the Linux sense — anything wanting `systemd`, or a supervisor that
reaps the world — do not work, and SatL fails them explicitly instead of
half-starting them.

### No IPVS — DNS round-robin, and no service VIP

Docker Swarm balances traffic to a service through a virtual IP backed by IPVS
in the kernel. FreeBSD has no IPVS, so SatL has **no service VIP at all**:
`Endpoint.VirtualIPs` is always empty and `EndpointSpec.Mode: "vip"` is a 400.

Service discovery is DNS round-robin instead. Each node runs an embedded DNS
responder bound to the overlay gateway addresses it holds; a service name
resolves to the addresses of its **running** tasks, shuffled per query. The
consequences are the ones DNS-RR always has, and they are worth knowing before
you rely on it:

- balancing is per DNS lookup, not per connection, and a client that caches or
  resolves once will pin itself to one replica;
- a task is not answered for until it is `RUNNING`, which is exactly why
  healthchecks gate that state — an unhealthy replica is simply absent from
  the answer;
- there is nothing to fail over *to* at the address level, because there is no
  address that outlives a task.

### No network namespace to hang a routing mesh in — so the mesh is pf

Docker's routing mesh works because every node can accept a connection on a
published port in a dedicated ingress namespace and forward it, internally, to
a task on some other node. FreeBSD jails have no per-namespace iptables to
build that with — so SatL's mesh is expressed in pf, on the node itself.

`--publish 8080:80` in SatL means: the port is allocated once, cluster-wide,
exactly as SwarmKit allocates it — and **every manager answers on it**. A
manager that runs no task of the service redirects the connection to a task's
*overlay* address on another node, with return-path SNAT so the reply comes
back through the relay. Round-robin across the live tasks is a pf table the
daemon keeps current; a task that dies leaves the pool within seconds.

Two properties fall out of building it this way, and both are measured facts
rather than aspirations:

- **A relayed connection loses the client address** — the SNAT that makes the
  return path work is also what hides the client. Docker's mesh makes the same
  trade. The remedy is opt-in: a service labelled
  `satl.publish.proxy_protocol=v2` is published through `satld`'s userspace
  proxy instead of pf, and the task sees the real address in a PROXY v2
  header. See [Publishing ports](../use/publishing-ports.md#the-client-address).
- **The mesh is managers-only.** A worker holds no store replica to compute
  the cluster-wide pool from, so a worker answers a published port only when
  it runs a task of the service itself — the pre-mesh behaviour. On an
  all-manager cluster the distinction is invisible; on a cluster with workers
  it is the one thing to know.

## Linux images, under the linuxulator

FreeBSD's Linux ABI layer lets `linux/amd64` images run. `satld` probes for it
at startup and says so:

```
INFO satld::node: linuxulator available; linux/* images may be selected osrelease=5.15.0
```

Platform selection prefers `freebsd/amd64` (or `arm64`) from a manifest list
and falls back to `linux/amd64`; `satl ps` and `satl images` carry a `PLATFORM`
column so you always know which one you got.

```console
$ satl images
REPOSITORY                               TAG      IMAGE ID       CREATED        SIZE      PLATFORM
127.0.0.1:5000/satl-test/alpine          latest   79ff19e9084a   56 years ago   3.846MB   linux/amd64
127.0.0.1:5000/satl-test/freebsd-nginx   latest   af645a19660d   56 years ago   15.63MB   freebsd/amd64
```

("56 years ago" is not a property of these two images. The daemon records no
creation timestamp, so [every image reads as the
epoch](../use/images.md#references); `SIZE` and `PLATFORM` are real.)

It needs `linux.ko` loaded and brings its own limits: an image that expects
cgroups, or that runs `systemd` as its entrypoint, is rejected with a clear
error rather than started half-way. In practice a musl or glibc userland that
just runs a binary works; a distribution image that wants to boot does not.
