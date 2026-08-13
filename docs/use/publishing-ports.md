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
is allocated once for the whole cluster and redirected on every node running a
task of the service.

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

## Ingress-lite: only nodes running a task answer

Docker's ingress is a **routing mesh**: every node in the swarm accepts
connections on a published port and forwards them internally to a node that has
a replica. SatL's ingress is not that.

!!! warning "The port answers on the nodes that run a task of the service, and only there"

    The port is allocated centrally, exactly as SwarmKit allocates it — one
    cluster-wide owner per (protocol, published port), sticky across updates,
    auto-assigned from 30000–32767 when the request says `0` — and it is then
    redirected **on each node that runs a task, to that node's own task**. A
    node running no task of the service refuses the connection.

Three consequences follow directly:

- **A load balancer in front of the swarm must health-check the port.** It must
  not assume every node serves it. A node with no replica is not a degraded
  backend — it is a correct one, refusing a port it does not host. A
  round-robin LB across all nodes with no health check will fail a predictable
  fraction of connections.
- **A service with fewer replicas than nodes is not reachable everywhere.**
  Scaling `web` to 2 on a 3-node cluster means one node stops answering, and
  nothing about that is an error.
- **There is no second hop, so the source address a container sees is the real
  client's.** That is a genuine improvement over a mesh, and worth knowing if
  you log client addresses.

The full routing mesh is future work.

## Two tasks of one service on one node

They share one rule, with a pf address pool:

```
rdr pass inet proto tcp from any to any port 8080 -> { 10.88.0.2, 10.88.0.3 } port 80 round-robin
```

That is what to expect in the anchor after scaling a service past the node
count, and momentarily during a rolling update while a slot's old and new tasks
overlap. Connections alternate between that node's own tasks.

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
4. **Does this node run a task of the service?** `satl service ps <service>`.
   If it does not, the refusal is correct.
5. **Is the container serving at all?** `curl <task ip>:<container port>` from
   the node, using the address in `/var/db/satl/net/<network>.json`.
6. **What did the daemon load?**
   `sudo grep -a 'published ports converged' /var/log/messages` — one line per
   change, with every redirect spelled out.
