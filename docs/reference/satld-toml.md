# `satld.toml`

The daemon's configuration file.
Every key is optional (a missing file means all defaults), and **unknown keys are rejected at startup**, so a typo stops `satld` rather than being quietly ignored.

Default location: `/usr/local/etc/satl/satld.toml`.
Point `satld` elsewhere with `--config` (see [`satld`](cli/satld.md)); that flag is the only way to move it.
The file is flat: there are no `[sections]`, and every key below sits at the top level.

Four properties of the whole file, before the keys:

- **A missing file is fine; a malformed one is fatal.**
  No file at all means every default below.
  A file that does not parse, or that contains a key not on this page, stops the daemon with the reason.
- **No environment variable overrides any of these.**
  There is no `SATL_*` equivalent for any key.
  (`RUST_LOG` sets the log level and `DOCKER_HOST` points the *client* at a socket; neither is a configuration key.)
- **Exactly one key has a command-line override**: `metrics_addr`, by `--metrics-addr`, and the flag wins.
- **Nothing here is re-read while running.**
  Changing any of it means restarting `satld`, which does not stop the node's containers.
  See [The rc.d service](../config/service.md#what-a-restart-does-and-does-not-touch).

Not everything is checked when the file is parsed.
Values that describe the host (paths, dataset names, interface names, the advertised address) are taken verbatim at load and validated when they are first used, so their failures appear in the startup log rather than as a parse error.
Where that distinction matters it is called out per key below.

!!! warning "The shipped sample is not the whole list"

    [`satld.toml.sample`](satld.toml.sample) documents 14 of the 16 keys.
    `cert_validity` and `overlay_blackhole` are absent from it.
    That gap is exactly the class of drift this page and its check exist to close.

## Keys

### `socket_path`

Unix socket the Docker-compatible REST API is served on.

**Type** path.
**Default** `/var/run/satl.sock`.

The socket is created mode `0660`, which together with its group is the entire access control on the API; there is no per-user identity on it.
Anyone who can write to it can create containers, and a container is root on the host, so treat write access to this socket as root access.
Moving it means every client has to be told: `satl --host unix:///new/path`, or `DOCKER_HOST` in the environment.

The path is not checked at load; a socket in a directory that does not exist fails when the daemon binds it.

### `state_dir`

Node state directory, normally the mountpoint of the ZFS root dataset.

**Type** path.
**Default** `/var/db/satl`.

Holds this node's identity and everything that is not a container: `certs/` (the node certificate and key, and the cluster trust bundle), `raft/` (the replicated log, its snapshots, and the `dek` file that seals them), the worker's task database, the co-located agent's socket, and, on a worker, its list of managers.

It should be the mountpoint of [`zfs_root`](#zfs_root).
When the two disagree `satld` **warns and starts anyway**: they can legitimately differ, but they usually differ by accident, and the warning is the only sign.
What lives here, and what may be deleted safely, is [Node state on disk](../config/state.md).

### `zfs_root`

ZFS root dataset holding every SatL dataset.
ZFS is mandatory: `satld` refuses to start when this dataset does not exist.

**Type** string.
**Default** `zroot/satl`.

The default matches what a stock FreeBSD root-on-ZFS install gives you.
If your pool has another name, this is the one key an otherwise-default install must set.

You create the root dataset only; `satld` creates the five children it needs (`raft`, `images`, `layers`, `containers`, `volumes`) on first start.
The name is not validated at load: the check happens in the storage preflight at startup, and the refusal names the exact `zfs create` command to run.

### `node_name`

Name this node reports in cluster and API output.
Defaults to the hostname.

**Type** string.

Cosmetic in the sense that nothing is addressed by it; a node's identity is the id in its certificate, which the cluster issues and you cannot choose.
Renaming a node therefore changes what `satl node ls` prints and nothing else.
Placement constraints can match it (`node.hostname == …`), so changing it on a node that constraints name will move tasks.

### `socket_group`

!!! danger "Accepted, printed, and not applied"

    This key does nothing today.
    `satld` parses it and names it in the startup banner, and no code anywhere changes the socket's group.
    The socket is created `0660` and keeps whatever group the daemon runs with, `wheel`, since `satld` runs as root.

    The default is therefore correct by accident, and **any other value is silently ignored**.
    Setting `socket_group = "satl"` in the belief that it narrows who can drive the daemon leaves the socket exactly as it was, and nothing warns you.

    This matters because anyone in the socket's group can create containers, which is root-equivalent on the host.
    To restrict it today, change the socket's group yourself after the daemon starts.

Intended meaning: the group owning the REST API socket.

**Type** string.
**Default** `wheel`.

### `pf_mode`

How the node-local network manager applies its `pf(4)` rules: `enforce`,
`check` or `disabled`.

**Type** one of those three strings.
**Default** `check`.

| Value | What happens |
| --- | --- |
| `enforce` | rules are generated, syntax-checked and **loaded** into the `satl/*` anchors. What a working node runs. |
| `check` | rules are generated and syntax-checked, and **never loaded**. The default. |
| `disabled` | rules are generated and logged; `pfctl` is never invoked at all. For a host without pf. |

The default being `check` is the trap every stock install meets: published ports are allocated, reported by `satl ps`, and redirected nowhere, with no error anywhere.
Set `enforce` and declare the three anchor lines in `/etc/pf.conf`; see [Publishing ports](../use/publishing-ports.md) and [the pf contract](ports.md#pf).

!!! warning "`enforce` assumes this daemon owns the host's `satl/*` anchors"

    `satl/rdr` is one anchor per host, and a daemon in `enforce` writes the whole of it.
    Two `satld` instances in `enforce` on one machine therefore delete each other's rules as each reconciles.
    One daemon per host is the only supported arrangement, and this is what makes it so.

### `network_name`

Name of the node-local bridge network, also the interface group and, suffixed
with `0`, the bridge interface name.

**Type** string.
**Default** `satl`, giving the bridge `satl0`.

**At most 14 characters**, and a longer value is refused at load.
`IFNAMSIZ` is 16 on FreeBSD; the bridge name is this value plus a `0`, and the NUL takes the last byte.
The name is also validated against SatL's network-naming rules at load, so an invalid one fails the parse rather than the first `ifconfig`.

It names three things at once: the network object, the interface group SatL marks everything it owns with, and the bridge.
Changing it on a node that already has containers leaves the old bridge behind.

### `network_pool`

Address pool the node-local network subnets are carved from.

**Type** CIDR string.
**Default** `10.88.0.0/16`.

Carved a `/24` at a time, one per network, with `.1` as the gateway on each.
Must parse as an IPv4 subnet at load.

This is **node-local addressing only**.
Overlay networks are allocated cluster-wide in Raft from a separate pool and are unaffected by this key; see [Networks](../use/networks.md#addresses).
Change it if `10.88/16` collides with something you route; there is nothing cluster-wide to keep in step, because each node's bridge subnets are its own.

### `egress_if`

Interface container traffic is NAT-ed out of.
Unset means "take it from the host default route at startup".

**Type** string.
**Default** unset.

The derivation is right on an ordinary single-homed host and is the reason this key is usually absent.
On a multi-homed host it may pick an interface you did not mean, and the symptom is asymmetric: no outbound connectivity from containers while inbound published ports still answer.
`satld` logs which interface it took, so check that line before setting this.

With no egress interface determined at all, no NAT rule is generated and the same asymmetric failure appears; [what to check](../use/networks.md#what-to-check-when-it-does-not-work).

### `listen_addr`

Address the internal gRPC server (Raft, Control, Dispatcher, NodeCA) binds.
The unauthenticated NodeCA bootstrap listener takes the next port up.

**Type** `host:port`.
**Default** `0.0.0.0:2377`.
Must parse at load.

**Every node listens here**, worker or manager; the dispatcher and certificate renewal need it even on a node that holds no store.
Mutual TLS is required on every connection to this port, so it is not a client port and no `satl` command talks to it.

The **second listener is derived, not configured**: it is this port plus one, `2378` by default, and it exists because a node that has never joined has no certificate to present and so cannot use the mTLS port at all.
That is the only place in SatL that accepts a connection without a client certificate, and it accepts nothing but the CA bootstrap calls.
Changing this port therefore moves both; see [Ports and firewall](ports.md#mtls) and [the bootstrap port](ports.md#the-bootstrap-port).

### `advertise_addr`

The `host:port` peers are told to dial.
Unset means "derive it at startup from the interface carrying the default route".

**Type** `host:port`, or a bare address.
**Default** unset.

A bare address has `listen_addr`'s port appended, so `advertise_addr = "10.2.0.4"` and `"10.2.0.4:2377"` mean the same thing on a default install.

**Not validated at load.**
It is kept as text and resolved at startup, so an unusable value surfaces in the startup log rather than as a parse failure.
Set it whenever the derived answer would be wrong; a host whose default route leaves by a different interface than the one peers reach it on, which is the common case for a cluster on a private underlay alongside a public interface.

This is the key `satl swarm init --advertise-addr` points you at: the node is already a cluster by the time you could run that, so the address is changed here and applied by a restart.

### `overlay_blackhole`

The blackhole default remote every VTEP on this node is created with.
Unset derives it from the measured underlay prefix.

**Type** bare IPv4 address.
**Default** unset (derived).

`if_vxlan(4)` requires a default remote on every tunnel, and **every broadcast, multicast and unknown-unicast frame goes to it without consulting the forwarding table**.
Since SatL programs its forwarding table from the cluster store and wants none of that flooding, the default remote has to be an address that goes nowhere, hence a deliberately unroutable one, derived as the last usable host of the measured underlay prefix.

The address parses at load; its **semantics are checked at startup** against the underlay SatL actually measured, which is the only point where they can be checked.
Refused there: this node's own address, a multicast, broadcast or unspecified address, an address outside the underlay prefix, and the prefix's own network or broadcast address.

Set it only when the derivation picks something you do route.

### `cert_validity`

Validity of the node certificates this daemon issues.
**A testing knob**: it exists to make the certificate renewal window arrive in minutes instead of weeks.

**Type** duration string.
**Default** 90 days.

The duration needs an explicit unit: `s`, `m`, `h` or `d`.
`"90d"` and `"36h"` are valid; `"90"`, `"12w"` and `"90 days"` are all refused.

Two thresholds, and they are not the same kind of answer:

- below **one hour**, the value is accepted and draws a loud startup warning;
- below **one minute** it is refused outright, because renewal happens at 50–80 %
  of validity and a certificate that short expires faster than the cluster can
  reissue it.

Leave it unset on anything real.
A short validity does not make the cluster more secure; it makes every node's renewal path load-bearing every few minutes, and [an expired certificate breaks everything at once](../trouble/tls.md#expired-certs).

### `metrics_addr`

Address the Prometheus `/metrics` endpoint binds, mirroring dockerd's `--metrics-addr`; the CLI flag of the same name wins over this key, and the endpoint is **off when neither is set**.
Unauthenticated, exactly like dockerd's: bind a private address reachable by the Prometheus server and nothing else.
The scrape reveals cluster shape, task ids and per-task resource usage.
See [Metrics](../use/metrics.md).

**Type** `host:port`.
**Default** unset, meaning the endpoint does not exist.
Must parse at load.

There is no authentication and no TLS on it, so `0.0.0.0` publishes your cluster's shape to anyone who can reach the port.

### `keyring_rotate_after_secs`

How old an encrypted overlay network's keyring may get before the leader rotates it, in plain seconds (default `43200`, Docker's 12 h).
**A testing knob**: shortening it lets a test watch a full rotation in minutes.
A zero value is refused at load, and any non-default value draws a loud startup warning.

**Type** integer seconds.

Zero is refused because the leader would find every keyring due and re-rotate them in a hot loop.

### `keyring_phase_settle_secs`

The settle between a keyring rotation's phases, in plain seconds (default `60`).
Refused at load when it does not fit below `keyring_rotate_after_secs`; a non-default value draws the same startup warning.
Never set either keyring knob on a real cluster.

**Type** integer seconds.

A rotation adds the new key everywhere before removing the old one, and the settle is the pause that lets every node pick the addition up before anything is withdrawn.
It has to be strictly less than the rotation interval, or a rotation could not finish before the next was due, which is what the load-time refusal checks.

## The shipped sample

[`satld.toml.sample`](satld.toml.sample) is copied verbatim from the SatL tree
by `make gen`, so it is always the sample that ships with the version of SatL
this reference was built from.
