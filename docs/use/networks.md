# Networks

Every SatL container gets a VNET jail — its own network stack, its own routing
table, its own interfaces — and one `epair(4)` connecting it to a bridge on the
host. That is the whole node-local picture:

```
     host                                  jail (VNET, one per task)
  ┌──────────────────────────────┐      ┌───────────────────────────┐
  │  satl0 (bridge)              │      │  epairNb                  │
  │   inet 10.88.0.1/24  ────────┼──────┤   inet 10.88.0.5/24       │
  │        │                     │      │   default route → .1      │
  │   epairNa (member)           │      │                           │
  │                              │      │  container process        │
  │  ice0 (egress) ── pf nat ────┼──▶   └───────────────────────────┘
  └──────────────────────────────┘
```

The `a` end of the epair joins the bridge; the `b` end is moved into the jail,
addressed, and given a default route to the bridge's address. One bridge per
network, one epair per task.

--8<-- "ops-manager-only.md"

## Addresses

The node's own bridge network is named by
[`network_name`](../config/satld-toml.md#networking) (default `satl`, on bridge
`satl0`) and carved out of [`network_pool`](../config/satld-toml.md#networking)
(default `10.88.0.0/16`) — a /24 per network, with `.1` as the gateway.
Addresses are stable per task and persisted on the node, so you can read the
mapping straight off disk:

```console
$ sudo cat /var/db/satl/net/satl.json
{
  "name": "satl",
  "subnet": "10.88.0.0/24",
  "allocations": {
    "2qw3gxb4uklpaowonekzukj02": "10.88.0.5"
  }
}
```

Overlay networks are different in one respect that matters constantly: an
overlay's addressing is allocated cluster-wide in Raft from a separate pool
(default `10.100.0.0/14`, /24 per network), but **its gateway address is per
node**, not cluster-wide. Every participating node's bridge sits on one L2
segment, so a single shared `.1` would be a duplicate address on that segment —
the jails would resolve their gateway to whichever node won the ARP race, and
that node would then receive everyone's egress traffic and everyone's DNS
queries.

So `satl network inspect` reports **this node's** gateway on the network, and a
node running no task on it reports none at all. That is not an inconsistency
between nodes; it is the correct answer to a question that has a different
answer on each of them.

## Container DNS

Each task's `/etc/resolv.conf` gets one `nameserver` line per attached network,
each pointing at this node's gateway address on that network. Every node runs an
embedded responder there.

A service name resolves to its running tasks' addresses, shuffled per query.
There is no virtual IP: FreeBSD has no IPVS, and `EndpointSpec.Mode: "vip"` is
refused rather than silently downgraded. DNS round-robin is the load balancing.

Two properties are worth internalising:

- **Which names resolve does not depend on which `nameserver` line the stub
  resolver picked.** The responder identifies the querying task by its source
  address and answers from *every* network that task is attached to. Scoping to
  the socket instead would mean a task on two networks got `NXDOMAIN` for every
  service on the other one — an authoritative denial a stub caches and does not
  retry on the next line.
- **Networks are searched in the order the service spec declares them**
  (`--network` order), and **the first network holding the name answers it,
  whole**. Two services of the same name on two of a task's networks resolve to
  whichever network the spec lists first, and the two answer sets are never
  merged into one round-robin pool.

Only `RUNNING` tasks are answered with, which is what makes a
[healthcheck](healthchecks.md) gate traffic rather than merely report on it.

??? note "Queries from somewhere else are forwarded, not answered"

    An overlay's per-node gateway addresses all sit on one L2 segment, so every
    task of the network — on every node — can reach every node's responder. A
    query whose source address is not one of *this* node's tasks is forwarded
    upstream instead of answered from the table, so one tenant's service names
    are not leaked to another. In normal operation nothing hits this: a
    container talks to its own node. A container that hardcodes another node's
    gateway gets its names forwarded to the host's resolvers instead.

    Two smaller differences from Docker: the qualified `<name>.<network>` form
    is not implemented, so a service must be uniquely named across a task's
    networks to be addressable; and with no upstream resolver configured, an
    unknown name is `NXDOMAIN` rather than `SERVFAIL`.

## Creating a network

```sh
satl network create --driver overlay backend
satl network create --driver bridge --subnet 10.90.7.0/24 lab
satl service create --name api --network backend registry.example.com/api:1
```

[`satl network`](../reference/cli/network.md#satl-network) has `ls`, `create`,
`inspect` and `rm`, and that is the complete list. `--driver`, `--subnet`,
`--gateway` and `--label` are the create options; `--attachable`, `--internal`,
`--ipv6`, `--opt` and `--aux-address` are absent from the CLI rather than
accepted and refused, because none of them can be honoured.

`SCOPE` is a consequence of the driver, never a separate choice: `overlay` is
`swarm`, `bridge` is `local`. A create whose scope contradicts its driver is a
400, not a network with the other scope. `local` is accepted as a synonym for
`bridge`, since that is the scope SatL reports for it and operators type it.

Networks are IPv4 only. `EnableIPv6` and any IPv6 subnet are refused, as are
`Internal` (every SatL network has egress through the node's NAT anchor),
`Attachable` (every container is already a task of a service), `ConfigOnly` and
`ConfigFrom`, driver options, and a second `ingress` network.

An overlay network also carries a `Vni`, the VXLAN network identifier the
allocator assigned — a SatL field, present on overlay networks and absent on
bridge networks and before allocation.

!!! info "A `bridge`-driver network is recorded, not programmed"

    Creating one succeeds with a warning. It becomes a real store object that
    services can reference, but tasks attach to the node's own bridge rather
    than to a bridge of their own. If you want traffic actually separated between
    services, that is an overlay network.

## There is no `bridge`, `host` or `none`

```console
$ satl network ls
NETWORK ID   NAME   DRIVER   SCOPE
```

An empty list on a working node is the expected output, and it is the single
most surprising thing on this page for a Docker user.

Docker's three predefined networks **do not exist** in SatL. The network list
holds store objects only, and the node's own bridge — `network_name` in
`satld.toml`, `satl0` on the host — is not one of them. It is node-local
plumbing, not a cluster object, so there is nothing to list.

What still works is the name: `NetworkMode` on container create accepts `""`,
`default`, `bridge` and `satl`, all meaning "the node's own bridge". Anything
else is a 400. `--network host` and `--network none` have no equivalent — a jail
without VNET or without any interface is not something SatL creates.

## `connect` and `disconnect` are refused, on purpose

```console
$ docker -H unix:///var/run/satl.sock network connect backend web
Error response from daemon: cannot attach container web to network backend: a
task's network attachments are allocated once, at creation, [...]. Declare the
network when the service is created (`--network backend`)
```

`satl network` has no `connect`/`disconnect` verbs, and the REST endpoints answer
501. This is a deliberate refusal rather than a gap someone forgot to fill.

A task's attachments are allocated once, when it is created, and its spec is
immutable afterwards. Hot-plugging a network onto a running container therefore
means *replacing the task* — a different container id than the one the client
named, which is the same wall that stops [`start` on a stopped
container](containers-and-services.md#start-on-a-stopped-container-is-refused).
The alternative would be to mutate the owning service's network list and answer
200, which would change the store and change nothing about the running
container. A clear refusal beats a store that claims an attachment the container
does not have.

The network and the container are still resolved before the refusal, so a typo
gets you a 404 rather than a misleading 501.

To change a service's networks, update the service — which replaces its tasks,
and is what a [rolling update](rolling-updates.md) is for.

## Removing a network

`satl network rm` is a 409 while anything still uses the network: a non-terminal
task attached to it *or naming it in its spec*, or a service whose task template
references it.

```
network backend has active endpoints: 3 task(s) are still attached, starting with …
network backend is in use by service api: its next task could not be placed without it
```

Both halves matter. Removing under a live task would black-hole it *and* let the
allocator hand its subnet out again; removing while a service still names it
would leave that service unable to place its next task. Terminal tasks do not
block removal, where Docker counts a stopped container's endpoint.

## What to check when it does not work

--8<-- "ops-log-first.md"

The two most common node-level causes are host settings rather than SatL
settings, and both are reported at startup:

```sh
sysrc gateway_enable=YES              # containers are routed, so the host must forward
sysctl net.inet.ip.forwarding=1
```

Without forwarding, containers have **no outbound connectivity while published
ports still answer**, which reads as a container problem rather than a host one.
`satld` warns about it explicitly:

```
WARN net.inet.ip.forwarding=0: containers will have NO OUTBOUND connectivity
     (published ports still answer, which makes this easy to misdiagnose).
     Run `sysrc gateway_enable=YES` and `sysctl net.inet.ip.forwarding=1`.
```

The second is the egress interface: with none determined, no NAT rule is
generated and the same asymmetric symptom appears. `satld` says which one it
took, and [`egress_if`](../config/satld-toml.md#networking) overrides it on a
multi-homed node.
