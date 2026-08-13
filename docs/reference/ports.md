# Ports and firewall

Everything SatL listens on, who is expected to reach it, and the `pf(4)` contract
it needs on each node. This page is meant to be handed to whoever runs the
network.

## Summary

| Port | Proto | Bound by | Reached by | Authentication |
| --- | --- | --- | --- | --- |
| **2377** | TCP | every manager | other nodes in the cluster | **mutual TLS** against the cluster root |
| **2378** | TCP | every manager | a node that is joining, once | **none** — see [below](#the-bootstrap-port) |
| **4789** | UDP | every node with an overlay task | other nodes in the cluster | none (VXLAN) |
| `/var/run/satl.sock` | unix | every node | local operators and tooling | filesystem permissions (`0660`) |

Published container ports are separate and are whatever your services ask for,
plus the dynamic ingress range **30000–32767** for ports the allocator assigns.

**Nothing in this list needs to be reachable from the internet.** 2377, 2378 and
4789 belong on the cluster's private network; the API socket is a unix socket and
is not on the network at all.

## 2377/TCP — the internal mTLS listener { #mtls }

One TCP listener carries every internal service:

| Service | What crosses it |
| --- | --- |
| Raft | log replication, votes, snapshots between managers |
| Control | follower → leader forwarding of store mutations |
| Dispatcher | the worker↔manager session: heartbeats, assignments, task status |
| NodeCA | certificate signing for nodes that already have an identity |
| Health | liveness probes between managers |

Properties a network admin needs:

- **Mutual TLS, always.** Both ends present a certificate issued by the
  cluster's own root CA, and both verify the other against the cluster trust
  bundle. A peer whose certificate names a different cluster, or chains to a
  root that has been rotated away, is refused at the handshake.
- **Workers open the connection; managers never dial workers.** The dispatcher
  session is established outbound by the worker and maintained by it. That makes
  the firewall rule one-directional: **nodes need to reach managers on 2377, not
  the other way round.**
- Managers do dial each other on 2377 for Raft, so between managers the rule is
  symmetric.
- The address is `listen_addr` in [`satld.toml`](satld-toml.md) (default
  `0.0.0.0:2377`), and what peers are told to dial is `advertise_addr`. Set
  `advertise_addr` explicitly on a multi-homed node — unset, it is derived from
  the interface carrying the default route, which on a cloud instance is usually
  the public NIC rather than the private network you meant.

## 2378/TCP — the NodeCA bootstrap { #the-bootstrap-port }

`satl swarm join host:2377` derives this port itself; it is always
`listen_addr`'s port plus one.

**Why an unauthenticated port is not a hole.** A node joining for the first time
has no certificate — that is the entire point of joining — so it cannot present
one on the mTLS port, and rustls builds a single mandatory client verifier for a
server, admitting no per-service exception. Hence a second listener.

What makes it safe is the join token:

1. The token is `SATL-1-<digest>-<secret>`, and `<digest>` is a hash of the
   cluster's **whole root CA trust bundle**.
2. The joiner connects to 2378 and downloads that bundle.
3. It hashes what it received and **refuses to proceed unless the hash matches
   the digest in its token**, with a message saying a man in the middle may have
   replaced or appended a root certificate.
4. Only then does it submit a signing request, authenticated by the token's
   secret, and receive a certificate. Every subsequent connection it makes is
   mTLS on 2377.

So the untrusted channel carries exactly one thing — a public trust bundle — and
that thing is pinned out of band by a token you copied from a manager. An
attacker who can intercept 2378 cannot substitute their own CA, and one who
cannot read the token cannot obtain a certificate.

Two consequences worth writing on the firewall ticket:

- **2378 only matters while a node joins.** It is harmless to leave open on the
  private network and equally harmless to open only during a join.
- **A join token is a credential.** Treat it like a password: it is void the
  moment the root CA is rotated, and it should never appear in an argv.

## 4789/UDP — VXLAN { #vxlan }

- The overlay data plane. One UDP socket per node, shared by every overlay
  network on it: several VXLAN interfaces with the same local address and
  different VNIs all use it, each keeping an independent forwarding table.
- **Unicast only.** SatL programs the forwarding tables from its own cluster
  state and never uses multicast, so no multicast routing or IGMP snooping is
  required of the fabric.
- **Not encrypted.** VXLAN carries the container traffic as it is. Run the
  underlay on a private network you trust, or accept that container-to-container
  traffic between nodes is in the clear.
- **The MTU matters more than usual.** VXLAN over IPv4 costs **50 bytes**; SatL
  sets the overlay MTU to the measured underlay MTU minus 50. A path that drops
  IP fragments turns a wrong MTU from a throughput problem into a hang — see
  [the overlay troubleshooting page](../trouble/overlay.md#fragmentation).
- The module is not in the GENERIC kernel. `satld` runs `kldload -n if_vxlan`
  itself, but `if_vxlan_load="YES"` in `/boot/loader.conf` makes a failure
  surface at boot rather than on the first overlay network.

## The API socket { #socket }

- `/var/run/satl.sock` by default (`socket_path` in `satld.toml`), mode `0660`,
  owned by the user and group `satld` runs as — root, so `root:wheel` on a stock
  FreeBSD host.
- There is **no TCP listener for the Docker API**, and no configuration key to
  ask for one. Remote access means SSH, or forwarding the socket yourself.
- Anyone who can reach this socket can run containers as root on the node.
  Treat membership of its group as equivalent to root.

## The pf contract { #pf }

SatL owns the `satl/*` anchors and **never touches rules outside them**. The
daemon refuses, in code, to load into any anchor outside `satl`/`satl/*`. It
regenerates the whole anchor ruleset on every change — there are no incremental
edits — and re-asserts it periodically, so an anchor flushed by hand comes back
within a minute.

An operator declares the anchors once, in `/etc/pf.conf`. **Translation anchors
must come before filter rules**, as pf requires:

```pf
# /etc/pf.conf — the three lines SatL needs
nat-anchor "satl/*"
rdr-anchor "satl/*"
anchor     "satl/*"
```

A host with no firewall policy of its own needs nothing more than those three
lines plus a `pass`:

```pf
nat-anchor "satl/*"
rdr-anchor "satl/*"
anchor     "satl/*"

pass all
```

Enable it:

```sh
sysrc pf_enable=YES
service pf start          # or: kldload pf && pfctl -f /etc/pf.conf && pfctl -e
```

### What SatL puts in the anchors

| Anchor | Rule | Purpose |
| --- | --- | --- |
| `satl/nat` | `nat on <egress> inet from <subnet> to any -> (<egress>)` | container egress. The parentheses make pf re-evaluate the interface's address, so the rule survives a DHCP renewal or an interface that comes up later |
| `satl/rdr` | `rdr pass inet proto {tcp\|udp} from any to any port <host> -> <task ip> port <container>` | one per published port on this node. Several tasks of one service on one node share **one** rule with a `round-robin` address pool |

Read them back with:

```sh
pfctl -a satl/nat -s nat
pfctl -a satl/rdr -s nat
pfctl -a 'satl/*' -s all
```

An empty anchor reports `does not exist` — that is not an error.

### `pf_mode`

| Value | Behaviour |
| --- | --- |
| `enforce` | generate, syntax-check and **load** the anchors. Needed for published ports and for container egress. Requires pf enabled on the host |
| `check` (**default**) | generate and syntax-check only. Ports are allocated and displayed; **no redirect is installed and nothing answers** |
| `disabled` | generate nothing, for hosts where pf is unavailable |

### Host prerequisites for container traffic

Container traffic is *routed* between the bridge and the egress interface, so
the host must forward:

```sh
sysrc gateway_enable=YES              # persistent
sysctl net.inet.ip.forwarding=1       # immediate
```

Without it, the NAT rule matches nothing useful and containers have no outbound
connectivity — while inbound redirects still answer, which makes the symptom
confusing. `satld` checks the sysctl at startup and warns when it is off.

NAT also needs to know which interface to translate out of. `satld` takes the
interface of the host's default route unless `egress_if` is set in
`satld.toml`. Set it explicitly on a multi-homed node.

## A worked firewall policy

For a three-node cluster on a private network `10.2.0.0/16`, with services
published on the public interface:

| From | To | Port | Why |
| --- | --- | --- | --- |
| every node's private address | every manager's private address | 2377/tcp | Raft, dispatcher, control, NodeCA |
| a joining node's private address | one manager's private address | 2378/tcp | first-contact bootstrap (only while joining) |
| every node's private address | every node's private address | 4789/udp | VXLAN overlay |
| the internet, or your load balancer | every node's public address | the published ports | your services |
| your workstation | every node | 22/tcp | operations |

Nothing else. In particular, the Docker API is not on this list, because it is
not on the network.
