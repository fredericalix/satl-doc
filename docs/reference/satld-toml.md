# `satld.toml`

The daemon's configuration file. Every key is optional — a missing file means
all defaults — and **unknown keys are rejected at startup**, so a typo stops
`satld` rather than being quietly ignored.

Default location: `/usr/local/etc/satl/satld.toml`. Point `satld` elsewhere with
`--config` (see [`satld`](cli/satld.md)).

!!! info "Coming"

    The prose for each key is still to be written. The headings below are not
    decoration: `tools/check_config_keys.py` compares them against `struct
    ConfigFile` in the SatL source on every `make check`, in both directions —
    a key the daemon accepts and this page omits fails the build, and so does a
    key documented here that the daemon would refuse.

!!! warning "The shipped sample is not the whole list"

    [`satld.toml.sample`](satld.toml.sample) documents 14 of the 16 keys.
    `cert_validity` and `overlay_blackhole` are absent from it. That gap is
    exactly the class of drift this page and its check exist to close.

## Keys

### `socket_path`

Unix socket the Docker-compatible REST API is served on.

### `state_dir`

Node state directory, normally the mountpoint of the ZFS root dataset.

### `zfs_root`

ZFS root dataset holding every SatL dataset. ZFS is mandatory: `satld` refuses
to start when this dataset does not exist.

### `node_name`

Name this node reports in cluster and API output. Defaults to the hostname.

### `socket_group`

!!! danger "Accepted, printed, and not applied"

    This key does nothing today. `satld` parses it and names it in the startup
    banner, and no code anywhere changes the socket's group. The socket is
    created `0660` and keeps whatever group the daemon runs with — `wheel`,
    since `satld` runs as root.

    The default is therefore correct by accident, and **any other value is
    silently ignored**. Setting `socket_group = "satl"` in the belief that it
    narrows who can drive the daemon leaves the socket exactly as it was, and
    nothing warns you.

    This matters because anyone in the socket's group can create containers,
    which is root-equivalent on the host. To restrict it today, change the
    socket's group yourself after the daemon starts.

Intended meaning: the group owning the REST API socket.

### `pf_mode`

How the node-local network manager applies its `pf(4)` rules: `enforce`,
`check` or `disabled`.

### `network_name`

Name of the node-local bridge network — also the interface group and, suffixed
with `0`, the bridge interface name.

### `network_pool`

Address pool the node-local network subnets are carved from.

### `egress_if`

Interface container traffic is NAT-ed out of. Unset means "take it from the
host default route at startup".

### `listen_addr`

Address the internal gRPC server (Raft, Control, Dispatcher, NodeCA) binds.
The unauthenticated NodeCA bootstrap listener takes the next port up.

### `advertise_addr`

The `host:port` peers are told to dial. Unset means "derive it at startup from
the interface carrying the default route".

### `overlay_blackhole`

The blackhole default remote every VTEP on this node is created with. Unset
derives it from the measured underlay prefix.

### `cert_validity`

Validity of the node certificates this daemon issues. **A testing knob**: it
exists to make the certificate renewal window arrive in minutes instead of
weeks.

### `metrics_addr`

Address the Prometheus `/metrics` endpoint binds, mirroring dockerd's
`--metrics-addr` — the CLI flag of the same name wins over this key, and the
endpoint is **off when neither is set**. Unauthenticated, exactly like
dockerd's: bind a private address reachable by the Prometheus server and
nothing else. The scrape reveals cluster shape, task ids and per-task resource
usage. See [Metrics](../use/metrics.md).

### `keyring_rotate_after_secs`

How old an encrypted overlay network's keyring may get before the leader
rotates it, in plain seconds (default `43200` — Docker's 12 h). **A testing
knob**: shortening it lets a test watch a full rotation in minutes. A zero
value is refused at load, and any non-default value draws a loud startup
warning.

### `keyring_phase_settle_secs`

The settle between a keyring rotation's phases, in plain seconds (default
`60`). Refused at load when it does not fit below `keyring_rotate_after_secs`;
a non-default value draws the same startup warning. Never set either keyring
knob on a real cluster.

## The shipped sample

[`satld.toml.sample`](satld.toml.sample) is copied verbatim from the SatL tree
by `make gen`, so it is always the sample that ships with the version of SatL
this reference was built from.
