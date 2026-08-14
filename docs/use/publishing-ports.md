# Publishing ports

Publishing a port is where SatL differs from Docker in ways that are invisible
until they bite. This page is the one to read before you try.

```sh
satl run     -d -p 8080:80 registry.example.com/nginx:1     # host mode
satl service create --name web -p 8080:80 --replicas 3 registry.example.com/nginx:1   # ingress
```

Those two lines do genuinely different things. `satl run -p` publishes in **host
mode**: the port is bound on the node running the task, recorded on that task,
and shown in `satl ps`. `satl service create -p` publishes in **ingress mode**,
which is Docker's default and therefore what you get without asking — the port
is allocated once for the whole cluster and answered on **every manager**,
whether or not that manager runs a replica (the routing mesh, below).

## Before anything works

--8<-- "ops-pf-enforce.md"

pf itself must be loaded and enabled, and SatL's anchors declared. Translation
anchors have to come before any filter rule:

--8<-- "pf-anchors.md"

```sh
sysrc pf_enable=YES
service pf start
```

SatL owns `satl/nat` and `satl/rdr`, regenerates the whole anchor on every
change, and refuses in code to load into anything outside `satl/*`. Declaring
the anchors costs you nothing you already had.

Check what a node actually holds:

```sh
pfctl -a satl/rdr -s nat                 # an empty anchor reports "does not exist"
sudo grep -a 'published ports converged' /var/log/messages
```

The daemon logs one line **per change**, carrying every redirect as
`<task id>=<published>/<proto>-><task ip>:<container port>`. A node whose
published ports are steady logs nothing here and runs no `pfctl` at all —
silence is the healthy state.

## `curl localhost:<port>` on the publishing host never works

!!! danger "This is the single most common way to conclude, wrongly, that publishing is broken"

    ```console
    $ satl service create --name web -p 18080:80 registry.example.com/nginx:1
    $ curl localhost:18080
    curl: (7) Failed to connect to localhost port 18080: Connection refused
    ```

    Nothing is wrong. **pf applies `rdr` to packets *entering* an interface**,
    and a connection to `localhost` is generated locally — it never enters one,
    so no translation rule ever sees it. Docker on Linux makes `localhost:port`
    work with an extra iptables OUTPUT rule; pf has no equivalent that SatL
    uses.

    Test from another machine. That is what SatL's own cluster test does: it
    curls the VMs' public addresses from the dev host, never from the VM itself.

To reach a container from the host it runs on, use its own address on the bridge:

```console
$ satl inspect web | jq -r '.[0].NetworkSettings.IPAddress'
10.88.0.5
$ curl 10.88.0.5:80
```

`satl inspect` has no `--format` flag — it prints JSON and you pipe it. The same
answer is on disk, which is handy when the daemon is the thing you are
debugging:

```console
$ sudo cat /var/db/satl/net/satl.json
{ "name": "satl", "subnet": "10.88.0.0/24",
  "allocations": { "2qw3gxb4uklpaowonekzukj02": "10.88.0.5" } }
```

That address is reachable from the host directly — the bridge is on the host —
so it is the honest local test, and it also tells you whether the container is
serving at all before you start suspecting pf.

## The routing mesh: every manager answers

Docker's ingress is a **routing mesh**: every node in the swarm accepts
connections on a published port and forwards them internally to a node that has
a replica. SatL's ingress is that, built out of pf.

!!! success "The port answers on every manager, replica or not"

    The port is allocated centrally, exactly as SwarmKit allocates it — one
    cluster-wide owner per (protocol, published port), sticky across updates,
    auto-assigned from 30000–32767 when the request says `0`. Every **manager**
    redirects it into a pf table holding the live tasks' *overlay* addresses,
    round-robin: a task on the node itself is reached directly, a task on
    another node is reached across the overlay, with return-path SNAT so the
    reply comes back through the relaying manager. Failover is the pool:
    kill a replica and its address leaves every manager's table within
    seconds, with no client-visible gap.

    **Workers are the exception.** Computing the pool takes a store replica,
    which only managers have — so a worker answers a published port only when
    it runs a task of the service itself, the pre-mesh behaviour. Point a load
    balancer at managers, or health-check the port if workers are in the pool
    of backends.

What it costs, stated plainly:

- **A relayed connection loses the client address.** The SNAT that makes the
  return path work is what hides the client — Docker's mesh makes the same
  trade for the same reason. A connection that lands on a node hosting a
  replica is not relayed and keeps the real address. The opt-in remedy is
  below.
- **One userspace hop none at all.** A relayed connection is kernel-forwarded
  by pf, not proxied; the cost is the SNAT, not a copy.
- The pool targets the task's **container port at its overlay address**, so a
  relayed packet can never re-match a published-port rule — loop safety by
  construction.

## The client address, and the PROXY-protocol opt-in { #the-client-address }

A service that logs, rate-limits or geo-locates by client address cannot
accept the mesh's SNAT. For those, SatL has a second publish mode, opted into
with a **service** label:

```sh
satl service update --label-add satl.publish.proxy_protocol=v2 web
```

On a labelled service, the port never gets a pf redirect. Instead `satld`
itself listens on it — on every manager, as the mesh does — picks a healthy
task from the same set that feeds the pf table, dials it over the overlay, and
writes a **PROXY protocol v2** header before splicing the two streams. The
task sees the real client address; the application must parse the header
(nginx: `listen 80 proxy_protocol;` plus `set_real_ip_from`). TCP only — UDP
ports of a labelled service stay on the pf path.

The trade is the honest one: a userspace copy per connection and the daemon in
the data path, against the client address and health-aware member selection
that pf cannot do. If you do not need the address, stay on the mesh.

## pf does not health-check what it redirects to

It is a packet filter. A `round-robin` pool distributes connections and never
probes a target, so a container that stops answering on its port **keeps receiving
its share of the traffic**. Nothing in pf will ever fix that, and nothing should:
what takes a dead backend out of the pool is one layer up. An unhealthy task is
stopped, leaves the live set, and the next port pass rewrites the whole anchor
without it. Docker Swarm works the same way — IPVS does not probe backends either.

!!! warning "Without a probe, `RUNNING` only means \"the jail started\""

    Measured when publishing landed: the redirect was installed **5 ms** after
    `jail start`, while the nginx in that same jail needed **250 ms** to bind its
    port. So an unprobed published service is answered before it can serve — and,
    worse, stays answered after it stops serving, for as long as its jail is up.

    `satl service create -p` says so once, at creation, if the service has no
    healthcheck.

Because the probe is load-bearing here and nowhere else, **publishing a port
changes the probe defaults**: 5 s interval, 3 s timeout, 2 retries instead of
Docker's 30/30/3, wherever you left the field unset. That takes a dead backend out
of the pool in about 10 s instead of about 90 — and, because SatL *stops* an
unhealthy task rather than merely unrouting it, it also makes replacement that
much more eager.

That trade, the arithmetic for tuning it, and why a `satl run -p` container can
never be gated at all, are on one page rather than half on each:
[Publishing a port tightens the
defaults](healthchecks.md#publishing-a-port-tightens-the-defaults).

## One port, many tasks: the rule is static, the pool is a table

Whether a node runs two tasks of the service or none, the redirect reads the
same:

```
rdr pass inet proto tcp from any to any port 8080 -> <satl_p8080_tcp_80> port 80 round-robin
```

The pool is a pf **table**, not an inline address list. The ruleset is
generated once per port and left alone; membership is edited in place with
`pfctl -T replace` as tasks come and go, so a rolling update or a kill does not
reload the anchor — and an established connection keeps its member across a
membership swap. The table holds *overlay* addresses, so it covers the
cluster's tasks, not only this node's.

```sh
pfctl -a satl/rdr -t satl_p8080_tcp_80 -T show      # who the port currently serves
```

**Two separate rules for one published port would be a bug.** pf evaluates
translation rules in order and the first match decides, so every task but one
would look published and never receive a connection.

??? note "A round-robin pool with one dead address, and how it reads"

    The symptom of a stale entry in a two-address pool is distinctive:
    connections to one node fail **every other attempt**, in bursts of about
    five seconds. It is worth recognising because it looks like packet loss and
    is not.

    The historical cause was a manager-side pass republishing a task the manager
    had already ordered to stop — the node's own agent had removed the redirect,
    and the pass put it back, because the store's copy of that task was still
    `RUNNING` for a few hundred milliseconds longer. A redirect is now created
    only for a task whose desired state is still below `SHUTDOWN`, so an ordered
    stop cannot produce it. The grep that identifies it, if it ever comes back,
    is a task id appearing in a `converged` line *after* its own `removed` line:

    ```sh
    sudo grep -a -E 'published ports (removed|converged)' /var/log/messages
    ```

## The empty `PORTS` column means the opposite of what it means in Docker

```console
$ satl service ls
ID             NAME   MODE         REPLICAS   IMAGE                    PORTS
2kjm40q4jy14   web    replicated   1/1        …/freebsd-nginx:latest   *:8080->80/tcp

$ satl ps
CONTAINER ID   IMAGE                    COMMAND   CREATED   STATUS      PORTS   PLATFORM        NAMES
2qw3gxb4uklp   …/freebsd-nginx:latest   ""        …         Up 2 days           freebsd/amd64   web
```

The container's `PORTS` column is empty while the node it runs on is redirecting
port 8080 to it right now.

That is not a display bug. `Task.Status.PortStatus` — which feeds
`GET /containers/json`'s `Ports` and therefore the `PORTS` column — carries
**host-mode bindings only**, exactly as SwarmKit's executor reports them. The
values match Docker; what differs is what an empty column *means*:

| | Docker | SatL |
| --- | --- | --- |
| `PORTS` empty | the container has no host binding, and the port lives in the ingress namespace | the container has no host binding, **and there is a live `rdr` on this very node sending that port to it** |

So read the *service* for ingress publishing — `satl service ls`'s `PORTS`
column, or `Endpoint.Ports` in `satl service inspect` — and read
`pfctl -a satl/rdr -s nat` for what a node actually redirects. `satl ps` answers
a different question.

A container published with `satl run -p` is host-mode and *does* show its
binding, which is why the two examples in this page's opening look
inconsistent. They are not: they publish differently.

## Syntax

`satl service create -p` takes Docker's short form only:
`[published:]target[/protocol]`, always ingress. The long `mode=host,…` CSV form
is not implemented, so host-mode publishing on a service is not reachable from
the CLI.

`satl run -p` takes `[ip:][hostPort:]containerPort[/protocol]`. The IP is
accepted, warned about, and ignored — the port is published on all addresses.
Port ranges (`8000-8010`) are rejected explicitly rather than half-honoured, and
the protocol may be `tcp` or `udp` (no `sctp`).

## The anchor repairs itself

`satld` re-derives the whole `satl/rdr` anchor from the tasks running on the node
every few seconds, and reloads pf only when the ruleset text changes. That is a
level, not an edge, and it has consequences worth relying on:

- a newly allocated port is answered within one pass, with no restart and no
  event;
- a `pfctl` load that fails is retried by the next pass, and the daemon never
  records a ruleset it failed to load;
- **an anchor flushed by hand comes back within a minute.** The daemon
  re-asserts the whole set unconditionally once a minute, because what it
  remembers is what it *loaded*, not what the kernel *holds*;
- one lost across a daemon restart comes back with the daemon
  (`ports_republished=1` in the startup reconciliation line).

## Checklist when a published port does not answer

--8<-- "ops-log-first.md"

1. **Are you testing from the publishing host?** `curl localhost` never works.
   Test from elsewhere, or use the container's bridge address.
2. **Is `pf_mode = "enforce"`?** The startup banner says: `pf_mode="enforce"`.
   With `check` the port is allocated and nothing is redirected.
3. **Is pf enabled and are the anchors declared?** `pfctl -s info`, and
   `pfctl -a satl/rdr -s nat` — "does not exist" means the anchor is empty, not
   that pf is broken.
4. **Is the node you are testing a manager?** The mesh answers on every
   manager. A worker answers only when it runs a task of the service —
   `satl service ps <service>` — and that refusal is correct.
5. **Is the container serving at all?** `curl <task ip>:<container port>` from
   the node, using the address in `/var/db/satl/net/<network>.json`.
6. **What did the daemon load?**
   `sudo grep -a 'published ports converged' /var/log/messages` — one line per
   change, with every redirect spelled out.
