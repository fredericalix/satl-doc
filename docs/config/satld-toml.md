# The daemon configuration file

`satld` is configured from one TOML file and almost nothing else. There is no
`--zfs-root`, no `--bridge`, no environment variable that quietly overrides a
setting: [the daemon's own flags](../reference/cli/satld.md) cover where the
file is and where the log goes, and everything else lives in the file.

Default location: `/usr/local/etc/satl/satld.toml`. Point elsewhere with
`satld --config /path/to/file`, which the rc.d service passes for you from
`satld_config` (see [The rc.d service](service.md)).

**Every key is optional and the file may be absent entirely.** A host with no
`satld.toml` runs on built-in defaults and starts perfectly well. That is worth
knowing because it changes how you should read the shipped
[`satld.toml.sample`](../reference/satld.toml.sample): it is a commented-out
list of the defaults, not a template you must fill in. Uncomment what you mean
to change and leave the rest alone.

This page walks the file in the order you actually decide things. For the
key-by-key detail — types, exact defaults, what each one accepts — go to the
[`satld.toml` reference](../reference/satld-toml.md).

## A typo is a startup failure, not a silent no-op

Unknown keys are rejected. `satld` refuses to start, names the file and names
the key:

```console
$ satld --config /usr/local/etc/satl/satld.toml
Error: malformed config file /usr/local/etc/satl/satld.toml: fix the file or remove it to run with defaults

Caused by:
    TOML parse error at line 1, column 1
      |
    1 | sokcet_path = "/tmp/x.sock"
      | ^^^^^^^^^^^
    unknown field `sokcet_path`, expected one of `socket_path`, `state_dir`, `zfs_root`, ...
```

This is deliberate. A configuration key that is accepted and ignored is the
worst failure mode a daemon has: the operator believes a setting is in force,
the daemon behaves as if it were not, and nothing anywhere says so. Values are
validated the same way — an unparseable `network_pool`, a `pf_mode` outside the
three it knows, a `listen_addr` without a port are all refusals at load time
with the offending key named.

The corollary is that **the startup banner is the authority on what took
effect**, not the file. It is the first line `satld` writes, and it prints the
effective configuration after defaulting:

```
INFO satld: starting satld version="0.1.0" git_commit="unknown"
     config_file=/usr/local/etc/satl/satld.toml config_source="file"
     socket_path=/var/run/satl.sock state_dir=/var/db/satl zfs_root=zroot/satl
     node_name=alpha.fredalix.com socket_group=wheel pf_mode="enforce"
     listen_addr=0.0.0.0:2377 ca_listen_addr=0.0.0.0:2378
     advertise_addr="(from the default route)"
```

`config_source="defaults (config file absent)"` there means the file was not
found at all — which, if you just wrote one, is the first thing to check.

## Storage, first, because it is the one that refuses to start

ZFS is not a driver among others in SatL; it is the substrate. Image layers are
datasets, applying a layer is a snapshot plus a clone, and a container's
writable layer is a clone of its image's top snapshot. `satld` will not start
without its root dataset.

`zfs_root` names that dataset (default `zroot/satl`) and it must already exist.
Create it before the first start, with the mountpoint SatL expects:

```sh
zfs create -o mountpoint=/var/db/satl zroot/satl
```

Everything below it — `raft`, `images`, `layers`, `containers`, `volumes` — is
created by the daemon on first start. Change `zfs_root` only if your pool is
not called `zroot`, or if you deliberately want SatL's data on another pool.

`state_dir` (default `/var/db/satl`) is the *filesystem path* side of the same
thing: where the daemon writes everything that is not a dataset — certificates,
the local task database, OCI bundles, container logs, IPAM state. It should be
the mountpoint of `zfs_root`, and `satld` warns at startup when the two
disagree. Setting one without the other is almost always a mistake. What lives
there is catalogued in [Node state on disk](state.md).

## The API socket, and who is allowed to drive the daemon

`socket_path` (default `/var/run/satl.sock`) is where the Docker-compatible
REST API is served. It is a unix socket, mode 0660, owned by root and by the
group in `socket_group`.

!!! danger "`socket_group` defaults to `wheel`, and socket access is root-equivalent"

    Anyone who can write to the API socket can start a container with a bind
    mount of `/` and a command of their choosing. There is no user-level
    authorization on the REST API: the socket permissions *are* the
    authorization model.

    The default is `wheel`, so **every member of `wheel` on the host can drive
    `satld` and is therefore effectively root**, whether or not they can `sudo`.
    On a machine where `wheel` means "people allowed to run `su`", that is
    probably what you want. On a machine where `wheel` has been handed out more
    loosely, it is not.

    The fix is a dedicated group:

    ```sh
    pw groupadd satl
    pw groupmod satl -m alice
    ```

    ```toml
    socket_group = "satl"
    ```

    A future package will create that group and make it the default; today you
    create it yourself.

`node_name` (default: the system hostname) is the name this node reports in
cluster output — the `HOSTNAME` column of `satl node ls` — and it is also the
name its Raft peer carries. Set it if the hostname is not what you want other
operators to read.

## pf: the setting that decides whether published ports work

`pf_mode` is the single most misread key in the file.

| Value | What `satld` does |
| --- | --- |
| `enforce` | generates the `satl/nat` and `satl/rdr` anchors, syntax-checks them, and **loads** them |
| `check` | generates them and syntax-checks them (`pfctl -nf -`), and never loads one |
| `disabled` | generates and logs them, and never invokes `pfctl` at all |

!!! warning "The default is `check`, which redirects nothing"

    With `pf_mode = "check"` — the built-in default — a published port is
    allocated, recorded on the task, and shown by `satl ps` and
    `satl service ls`. **Nothing on the host redirects it.** Connections to that
    port are refused, and the CLI gives you no hint, because from the control
    plane's point of view everything worked.

    Outbound NAT is in the same anchors, so `check` also means containers have
    no route to the outside world.

    `check` is the default on purpose: it is safe on a host whose pf ruleset is
    managed by something else, since it validates SatL's rules without touching
    the live ruleset. It is not a working configuration for a node that serves
    traffic.

`enforce` additionally requires pf to be enabled on the host and SatL's anchors
to be declared in `/etc/pf.conf`. SatL owns `satl/nat` and `satl/rdr`, writes
the whole anchor atomically on every change, and refuses in code to load into
any anchor outside `satl/*` — so declaring them costs you nothing you had. See
[Publishing ports](../use/publishing-ports.md) for the `/etc/pf.conf` lines and
the host prerequisites.

Use `disabled` on a host without pf, accepting that such a node can run
containers that talk to each other and to nothing else.

## Networking

`network_name` (default `satl`) names the node-local bridge network containers
attach to. It does three jobs at once, which is what makes it more consequential
than it looks: it is the network's name in `satl network ls`, it names the
bridge interface with a `0` appended (`satl` → `satl0`), and it is the
`ifconfig(8)` **interface group** SatL marks every interface it creates with.

That third job is the trap.

!!! danger "Two `satld` instances on one host must not share `network_name`"

    On startup, each daemon enumerates its interface group and destroys every
    interface in it that it cannot account for. That sweep is what makes SatL
    recover from an interrupted teardown — a leaked epair from a jail that died
    mid-removal is found and destroyed rather than accumulating.

    Give two daemons on one host the same `network_name` and each one's startup
    reconciliation destroys the other's epairs and bridges. Both lose their
    containers' networking, at every restart, and the log of each will show a
    sweep that did exactly what it was told.

    If you run a second instance — a test daemon beside a real one — give it its
    own `network_name`, and remember it changes the bridge interface name too.

The name is capped at 14 characters, because the bridge interface derived from
it has to fit FreeBSD's `IFNAMSIZ`. It also may not end in a digit, since
`ifconfig` refuses such interface group names.

`network_pool` (default `10.88.0.0/16`) is the address space node-local
networks are carved from, one /24 per network, `.1` being the gateway. Change it
if `10.88/16` collides with something on your underlay. Note this is *not* the
overlay pool: overlay subnets are allocated cluster-wide from a separate default
(`10.100.0.0/14`).

`egress_if` names the interface container traffic is NAT-ed out of. Left unset,
`satld` takes the interface carrying the host's default route, which is right on
an ordinary machine and is what the banner reports:

```
INFO satld::node: egress interface taken from the default route
     (set egress_if to override) egress_if=ice0
```

Set it explicitly on a multi-homed node — when containers must leave through a
private interface rather than the public one. With no egress interface at all,
no NAT rule is generated and the failure is asymmetric enough to be genuinely
confusing: published ports still answer, while the container itself cannot reach
a registry or a DNS server. `satld` warns loudly about that at startup.

## Cluster addresses

`listen_addr` (default `0.0.0.0:2377`) is where the internal, mutually
authenticated gRPC server binds — Raft, the control API, the dispatcher and the
node CA all share it. Every node listens, worker or manager: a manager needs it
for its peers, and a single-node cluster needs it for the nodes that will join
it later.

`satld` also binds **the next port up** (2378 by default) for the unauthenticated
node-CA bootstrap endpoint. A node that has never joined has no certificate to
present, so it cannot complete the mTLS handshake on 2377; it fetches the root
CA and submits its signing request on 2378 instead, and pins what it receives
against the digest baked into its join token. Both ports must be reachable from
every other node. An operator only ever types the first one — `satl swarm join
host:2377` derives the second itself.

`advertise_addr` is the `host:port` this node tells its peers to dial. Unset, it
is derived from the address of the interface carrying the default route, with
`listen_addr`'s port, and the banner says so (`advertise_addr="(from the default
route)"`, followed by a resolved line). Set it explicitly whenever the address
other nodes must use is not the one the default route leaves by — a dedicated
cluster network, for example. A bare address is accepted and gets `listen_addr`'s
port, so `advertise_addr = "10.2.0.4"` means `10.2.0.4:2377`.

??? note "What happens with no advertise address at all"

    The node still starts and still joins. The leader substitutes the address it
    observes the node connecting from, which is usually right and is never
    authoritative. The one place it matters beyond Raft is the VXLAN overlay:
    a node's tunnel endpoint is taken from what the node says about itself
    first, and only falls back to the observed control-plane address — which
    equals the underlay only for as long as agents happen to reach their
    managers over the underlay. A tunnel endpoint taken from that fallback is
    logged with a warning, because a wrong one does not fail loudly: the tunnel
    comes up, reports `RUNNING`, and carries nothing.

## Two keys you will probably never set

`overlay_blackhole` overrides the address every VXLAN tunnel on this node is
given as its default remote. It must be an address nothing answers on, because
its whole purpose is to make a missing forwarding entry fail instead of quietly
working on whichever peer it happened to point at. Left unset it is derived from
the measured underlay prefix. Set it only on a fabric that really uses the top
address of its prefix.

`cert_validity` sets how long the certificates this daemon issues are valid.
**It exists to test certificate renewal**, by making the renewal window arrive
in minutes instead of weeks. Values under an hour draw a loud startup warning
and values under a minute are refused at load. The production setting is to omit
the key entirely, which means 90 days.

Neither key appears in the shipped `satld.toml.sample`; both are in the
[reference](../reference/satld-toml.md), which is checked against the daemon's
own accepted key set on every build of this site.

## Changing it

There is no reload. `satld` reads the file once, at startup, so a change takes
effect on the next `service satld restart` — which, as [the next
page](service.md) explains, is much less disruptive than it sounds: running
containers are deliberately left alone and re-adopted.
