# What SatL does not do

Deliberate absences, honest ones, and what to do instead. Nothing on this page
is a bug; several items on it have real operational costs, and the point of
listing them together is so that you meet them here rather than in production.

The two entries you should read before running SatL for any length of time are
[disk reclamation](#no-prune) and [backup and restore](#no-backup).

## No image or layer reclamation { #no-prune }

!!! danger "Disk use grows without bound"

    There is **no `prune` of any kind and no layer garbage collection.** Nothing
    in SatL ever deletes an image, a layer dataset, or the content store entry
    behind them — not on image removal, not on service removal, not on a timer.
    Every image ever pulled on a node stays on that node's disk for as long as
    the node exists.

    A node that pulls a new tag on every deploy will fill its pool. This is the
    single most likely way to take a SatL node down.

What *is* reclaimed: a container's writable layer, when its task is removed —
possibly a minute late, and handled by a sweep that runs every 20 s.

**What to do instead.** Watch the pool and reclaim by hand:

```sh
zfs list -o name,used,refer -r zroot/satl
zfs list -t snapshot -r zroot/satl/layers | wc -l
```

Removing a layer dataset by hand is destroying data other images may share
through clones, so treat it as a last resort and check `zfs list -o
name,origin` before destroying anything. On a node you can afford to empty, the
supported reset is to destroy and recreate the whole state dataset — which also
destroys the node's identity and Raft state, so it is a rejoin, not a cleanup.

## No `satl compose` { #no-compose }

There is no `satl compose` verb and no Compose file support.

**What to do instead.** Write services. A Compose file's `services:` block maps
onto `satl service create` reasonably directly — image, command, environment,
networks, published ports, secrets — and what it does *not* map onto (build
contexts, `depends_on` ordering, `restart: unless-stopped` semantics) is either
absent here or means something different. For anything scripted, post
`ServiceSpec` documents to the REST API: it accepts the full Docker shape,
including the fields the CLI has no flag for.

## No `satl build` { #no-build }

There is no image build, no BuildKit, no `Dockerfile` support, and no
`/build` endpoint — it answers `404`. `/_ping` carries no `Builder-Version`
header for the same reason.

**What to do instead.** Build elsewhere and push to a registry SatL can pull
from. On FreeBSD, `skopeo` copies images between registries and preserves
multi-platform indexes byte for byte, which matters because platform selection
is exactly what those indexes are for. Note that SatL refuses a plain-HTTP
registry unless it is loopback.

## No packages, no binary releases, no `satl` group { #no-packages }

SatL is built from source with `make install`. There is no FreeBSD package, no
port, no signed tarball, and no `pkg` upgrade path.

There is also **no dedicated `satl` group**. The API socket is mode `0660` owned
by the user and group `satld` runs as — root, so `root:wheel` on a stock host.
The `socket_group` key in `satld.toml` is parsed and reported in the startup
banner but does not change the socket's ownership, so setting it to something
else has no effect on who can reach the API.

**What to do instead.** Add operators to `wheel`, or use `sudo`. Treat
membership of that group as equivalent to root on the node: anyone who can reach
the socket can run containers as root.

## No upgrade path { #no-upgrade }

There is no defined procedure for moving a running cluster from one version of
SatL to another, no compatibility statement between versions of the internal
gRPC protocol or the on-disk Raft format, and no rolling-upgrade orchestration.

**What to do instead.** Deploy the same build to every node. Treat a version
change as a change you rehearse on a cluster you can afford to rebuild.

## No tested backup or restore { #no-backup }

**There is no backup procedure, and no restore procedure has been tested.** This
section states what is known and stops there; do not read a runbook into it.

What is known, as facts:

- **cluster state lives in `<state_dir>/raft`** — the Raft log (`log.redb`), the
  snapshot, this node's cluster identity (`node-id`), its Raft member id
  (`raft-id`), and the `dek`;
- **the log and the snapshots are encrypted at rest** with the `dek`, which is a
  `0600` file in that same directory. Without it, that node's Raft state is
  unreadable. On a multi-manager cluster the node could re-sync from its peers;
  a single-node cluster's state would be lost;
- **a snapshot file appears after roughly 10 000 writes**, not before, so a fresh
  cluster's whole state is in the log;
- **crash recovery from that directory works** and is exercised: a `kill -9` on
  `satld` is followed by a restart that recovers cluster state and the same node
  identity;
- **certificates live in `<state_dir>/certs`**, and a node that loses them but
  keeps its cluster membership is a node that has to rejoin;
- **`ForceNewCluster` is not implemented** — the disaster-recovery path that
  Docker offers for reconstituting a cluster from one surviving manager answers
  `501` here.

What follows from those facts, and no further: copying `<state_dir>/raft` from a
stopped manager captures that manager's view of cluster state including the key
that decrypts it. Whether restoring such a copy onto a node produces a working
cluster has not been tested, and a partially restored Raft group is a worse
state than an empty one.

**What to do instead.** Keep the *inputs* recoverable rather than the state:
your service specs and network definitions as files you can re-apply, your
images in a registry, your secrets in whatever system you generated them from.
A SatL cluster is cheap to rebuild from those and expensive to reason about
half-restored.

## No routing mesh { #no-mesh }

`PublishMode: ingress` publishes without Docker's routing mesh: the port is
allocated cluster-wide and redirected **only on nodes that run a task of the
service**. A node with no replica does not answer.

**What to do instead.** Put a load balancer in front of the cluster and give it
a **health check on the port**. A node with no replica is a correct backend that
is currently down for that service, not a degraded one. The upside is that there
is no second hop, so your services see the real client address.

## No data-plane encryption { #no-encryption }

The control plane is mutual TLS everywhere. **The overlay is not encrypted.**
VXLAN carries container traffic between nodes as it is, on UDP 4789, and there
is no equivalent of Docker's `--opt encrypted` — a driver option map on a
network create is rejected rather than stored and ignored.

**What to do instead.** Run the underlay on a private network you control, and
put TLS inside the containers for anything that needs confidentiality between
services.

## No metrics endpoint { #no-metrics }

There is no `/metrics`, no Prometheus surface, and no counters exported
anywhere.

**What to do instead.** The daemon log is the observability surface, and it is
structured for it: every lifecycle transition carries `task_id`, `service_id`,
`node_id`, `jail_id` and `from`/`to` fields, `--log-format json` emits one
object per event, and `RUST_LOG` selects per-subsystem detail. Ship
`/var/log/messages` to whatever you already run, and see
[Reading the log](../trouble/reading-the-log.md) before you write parsers — one
event is one line, and that property is worth verifying on your own hosts.

## No IPv6 { #no-ipv6 }

SatL assigns no IPv6 addresses. Node-local and overlay IPAM are IPv4-only, and a
network create carrying `EnableIPv6` or an IPv6 subnet is rejected with a `400`
rather than accepted and quietly ignored. `IPv6Address` is always empty in
inspect output. IPv6 forwarding on the host is not required.

**What to do instead.** Nothing, yet. Published ports still work over whatever
the host's own addressing is; it is the container addressing that is v4-only.

## FreeBSD 15.1 amd64 only { #platform }

- **The host must be FreeBSD 15.1 on amd64.** Nothing else is built or tested,
  and the daemon leans on FreeBSD-specific interfaces throughout — jails, VNET,
  `rctl(8)`, `pf(4)`, `if_vxlan`, `devfs` rulesets, and ZFS.
- **ZFS is mandatory, not a driver among others.** `satld` refuses to start
  without its root dataset. Layers are datasets, applying a layer is a snapshot
  plus a clone, and a container's writable layer is a clone.
- **SatL implements no runtime.** It generates the OCI spec and drives the
  `ocijail` binary, which must be installed.
- **Container images may be `freebsd/*` or `linux/*`.** Linux images run under
  the linuxulator, which needs its kernel modules loaded on that node. Both musl
  and glibc images work.
- **Images expecting cgroups, systemd or a PID namespace will not work.** There
  is no cgroup filesystem, and a jail's entrypoint is never PID 1. An image whose
  entrypoint is an init system is rejected at task creation with a sentence
  explaining why, rather than dying silently a second later.
- SysV IPC is disabled in the jails SatL creates, OFD file locks return
  `EINVAL`, and anything needing netlink or `io_uring` fails.

## Smaller absences, in one place

| Not there | Instead |
| --- | --- |
| interactive TTY (`-t`), attach, live-streaming `exec` output | `satl logs`, and `exec` output delivered when the process exits |
| `docker cp` / archive endpoints | bind mounts and volumes |
| `commit`, `export`, `rename`, `restart`, `pause`, `update`, `top`, `stats`, `changes` | — (all answer `404`) |
| container links, `--network host`, `--network none` | one network model: the node bridge, or an overlay |
| network `connect`/`disconnect` on a running container | declare the networks in the service spec |
| server-side `?filters=` on nodes, services, networks, secrets, configs | filter client-side; the daemon answers `501` rather than silently listing everything |
| `satl events` as a CLI verb | `GET /events` is served — use `curl --unix-socket` |
| volume plugins and drivers other than `local` | ZFS datasets and host bind mounts |
| secret drivers, templating, and secret update | rotate by replacement |
| an autolock / unlock key for manager state | the `dek` is a file on disk, protected by its mode |
