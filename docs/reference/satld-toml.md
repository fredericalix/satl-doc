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

    [`satld.toml.sample`](satld.toml.sample) documents 11 of the 13 keys.
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

Group owning the REST API socket.

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

## The shipped sample

[`satld.toml.sample`](satld.toml.sample) is copied verbatim from the SatL tree
by `make gen`, so it is always the sample that ships with the version of SatL
this reference was built from.
