# Install

Prepare the host first, build second.
The order below is the order things depend on each other in; the daemon will start with several of these missing and degrade quietly, which is why they come first.

Everything here assumes you have been through
[Requirements](requirements.md).

## The short way

[`install-satl.sh`](../install-satl.sh) does steps 1 to 8 of this page in one command, on one node.

```sh
fetch https://docs.satl.cc/install-satl.sh
sh install-satl.sh --pkg https://satl.cc/download/satl-freebsd.pkg          # as root
```

Two steps rather than a pipe into `sh`, for the same reason step 5 downloads the package before installing it: you get to read what you are about to run.
`--help` lists the flags.
The ones worth knowing are `--zpool` (skip the pool prompt), `--with-registry` ([a local registry](registry.md) on this node), `--with-linux` (the linuxulator) and `--smoke-test` (pull and run a container at the end).

Every step is idempotent and prints `[ ok ]`, `[skip]` or `[warn]`, so a second run reads as a diff against the host rather than as an install.
`--verify-only` runs the closing checklist and changes nothing at all.

It does nothing cluster-shaped: no join, no `advertise_addr`, no `listen_addr`.
Those are decisions about addresses a script cannot make for you, and one node needs none of them -- [step 9](#9-verify) is where that stops being surprising.

!!! note "`/etc/pf.conf` is the only file it edits that was already there"

    It is copied to `/etc/pf.conf.satl-<timestamp>`, the three anchors are inserted ahead of the rules they have to precede, and the result goes through `pfctl -nf` **before** it is installed.
    A ruleset that does not parse is refused and your file is left untouched.
    And if pf is currently disabled while the ruleset is yours, the script asks before enabling it, defaulting to No: loading your own policy could drop the ssh session you are running in.

The rest of this page is what the script does, and why.
Read it when something goes wrong, or when you would rather do it by hand.

## 1. Storage

```sh
zfs create -o mountpoint=/var/db/satl zroot/satl
```

Substitute your pool name if it is not `zroot`, and remember to set `zfs_root` in `satld.toml` in step 6 if you do.
`satld` creates the `raft`, `images`, `layers`, `containers` and `volumes` children itself on first start.

## 2. IP forwarding

Container traffic is routed between the bridge and the egress interface, so the
host has to forward it.

```sh
sysrc gateway_enable=YES              # persistent, applies at next boot
sysctl net.inet.ip.forwarding=1       # applies now
```

Skipping this produces the single most misleading symptom in SatL: **inbound published ports answer and containers cannot reach anything.**
`satld` checks the sysctl at startup and warns, so the answer is in the log, but the shape of the failure looks like a container problem, not a host one.

## 3. pf anchors

SatL owns the `satl/*` anchors and never writes a rule outside them.
Declare them once: translation anchors before any filter rule:

--8<-- "pf-anchors.md"

```sh
sysrc pf_enable=YES
service pf start          # or: kldload pf && pfctl -f /etc/pf.conf && pfctl -e
```

An anchor that is not declared in `pf.conf` is never evaluated.
`satld` will happily load rules into it, report success, and change nothing about how packets move.

## 4. Boot-time tunables

--8<-- "loader-conf.md"

Reboot when convenient.
See [Requirements](requirements.md#the-reboot-and-deferring-it) for what you lose until you do.

## 5. Install SatL

Install the runtime, then download the package and add it:

```sh
pkg install ocijail
fetch https://satl.cc/download/satl-freebsd.pkg
pkg add ./satl-freebsd.pkg
```

`ocijail` comes first because `pkg add` installs the file it is given and nothing else: it never resolves a dependency from a repository, however well configured the repository is.
Skip it and the install refuses, measured on a stock 15.1 host:

```console
$ pkg add ./satl-freebsd.pkg
Installing satl-0.1.0...
pkg: Missing dependency 'ocijail'

Failed to install the following 1 package(s): ./satl-freebsd.pkg
```

Fetch and add stay two steps rather than one so you can see the file land before anything installs,
and so you can check it, keep it, or copy it to the other nodes of a cluster
instead of downloading it three times.

The package needs no repository of its own, and its post-install message recalls the host prerequisites you have just done (steps 1–4 of this page).
It installs the same four files a source build does, listed below.

!!! tip "One package, every node"

    A cluster wants the same build everywhere.
    `fetch` once, `scp` the file around, `pkg add` on each machine; mixing versions across nodes is not a configuration SatL is tested in.

[Install from source](install-from-source.md) replaces this step, and nothing else on this page.
Take it if you want a fix that is not in a release yet, or if you would rather build the `.pkg` for your own nodes; it is the only path that needs a Rust toolchain.

Either way you now have four files installed:

| Path | What |
| --- | --- |
| `/usr/local/bin/satl` | the CLI |
| `/usr/local/sbin/satld` | the daemon |
| `/usr/local/etc/rc.d/satld` | the rc.d service |
| `/usr/local/etc/satl/satld.toml.sample` | a commented sample config |

Note the last line carefully.

## 6. Write `satld.toml`: do not skip this

!!! danger "The install ships a sample, not a config"

    `pkg add`, like `make install`, writes `satld.toml.sample`.
    It does **not** create `satld.toml`.
    A missing config file is perfectly legal (the daemon runs on built-in defaults), and the built-in default for `pf_mode` is **`check`**.

    In `check` mode `satld` generates its pf rules and syntax-checks them, and never loads one.
    So on a stock install, a published port is allocated, recorded, and shown by `satl ps` exactly as if it worked:

    ```
    PORTS
    0.0.0.0:8080->80/tcp
    ```

    and no redirect exists.
    Nothing is logged as an error, because nothing failed.
    This catches essentially every first install.

Start from the sample rather than an empty file; it carries every key, with its default and the reason you would change it:

```sh
cp /usr/local/etc/satl/satld.toml.sample /usr/local/etc/satl/satld.toml
```

That copy on its own changes nothing, because every line in the sample is commented out; `pf_mode` is still `check`.
Uncomment it and set it to `enforce`.
Stripped of its comments, that is the whole config an ordinary first install needs:

--8<-- "satld-toml-minimal.md"

`pf_mode = "enforce"` needs pf enabled (step 3) and the anchors declared.
The third mode, `disabled`, generates and logs the rules and never invokes `pfctl` at all, for hosts with no pf.

Every other key is optional.
The commented sample lists them, and the [`satld.toml` reference](../reference/satld-toml.md) documents all sixteen, including two the sample does not mention.
The ones you are most likely to need on a real host:

- `zfs_root`, if your pool is not `zroot`.
- `egress_if`: on a multi-homed host, when containers must leave through a specific interface.
  Left unset, `satld` takes the interface of the default route.
- `advertise_addr`: the `host:port` peers are told to dial.
  Only matters once you cluster, and it matters a lot then: unset, a node advertises whatever the default route leaves by, which on a cloud VM is usually its *public* interface.
- `network_name`, if you will run two `satld` instances on one host.
  They must differ, or each one's startup reconciliation destroys the other's interfaces.

Unknown keys are rejected at startup, so a typo fails loudly rather than being
ignored.

## 7. Enable and start

```sh
sysrc satld_enable=YES
service satld start
service satld status
```

The rc.d script runs `satld` under `daemon(8)` with `--log-target syslog`.
Three optional `rc.conf` knobs:

| Variable | Default | Use |
| --- | --- | --- |
| `satld_config` | `/usr/local/etc/satl/satld.toml` | point at another config |
| `satld_flags` | empty | extra flags, e.g. `--log-format json` |
| `satld_env` | empty | environment, e.g. `RUST_LOG=satld=debug` |

!!! warning "If you edit the rc.d script, keep `--log-target syslog`"

    It is a correctness requirement, not a preference.
    With it, `satld` hands each log event to syslogd itself as its own datagram, so one event is one line.
    Without it, `daemon(8)` forwards the output in chunks and syslogd rewrites the newlines inside a chunk as spaces; measured on FreeBSD 15.1, that merged 3.9 % of lines and a synthetic burst lost **more than half** its records outright.
    Two timestamps on one line is this bug.

## 8. Read the startup lines

The daemon's log is the only place its output lands, under the tag `satld`, in
`/var/log/messages` and `/var/log/daemon.log`.

```sh
grep -a satld /var/log/messages | grep -av openraft | tail -40
```

The `grep -av openraft` matters on a first start: the embedded raft library logs its own startup at `INFO` under the same tag, verbosely enough to push every line below out of a bare `tail -40`.

!!! tip "Always `grep -a`"

    One non-ASCII byte anywhere in `/var/log/messages`, from any program on the host, makes `grep` treat the whole file as binary and print **nothing**, with exit status 1 and no explanation.
    That looks exactly like "the daemon logged nothing", which is the worst possible way to be misled.

A healthy first start, on this machine, verbatim:

```
INFO satld: starting satld version="0.1.0" git_commit="unknown"
     config_file=/usr/local/etc/satl/satld.toml config_source="file"
     socket_path=/var/run/satl.sock state_dir=/var/db/satl zfs_root=zroot/satl
     node_name=alpha.fredalix.com socket_group=wheel pf_mode="enforce"
     listen_addr=0.0.0.0:2377 ca_listen_addr=0.0.0.0:2378
     advertise_addr="(from the default route)"
INFO satl_storage::preflight: storage preflight complete root_dataset="zroot/satl" root_mountpoint=/var/db/satl
INFO satld: host information gathered hostname=alpha.fredalix.com ncpu=12 physmem_bytes=68258983936 os_release=15.1-RELEASE-p2
INFO satld::node: SatL devfs ruleset ready ruleset=5000 outcome=AlreadyCurrent
INFO satld::node: linuxulator available; linux/* images may be selected osrelease=5.15.0
INFO satld::node: kern.racct.enable=1; rctl(8) resource limits are enforced
INFO satld::node: egress interface taken from the default route (set egress_if to override) egress_if=ice0
INFO satl_net::pf: loaded pf anchor anchor=satl/nat rules=nat on ice0 inet from 10.88.0.0/24 to any -> (ice0)
INFO satld::node: node-local network ready network=satl bridge=satl0 subnet=10.88.0.0/24 gateway=10.88.0.1 pf_mode="enforce"
INFO satld::cluster: node identity loaded from disk node_id=1oihjf6ers1k3v6ow4lxiy5bd role="satl-manager" cluster_id=2ojl5schqxehkvo5femr07j2v
INFO satl_cluster::server: internal gRPC server listening addr=0.0.0.0:2377
INFO satld::cluster: cluster state ready node_id=1oihjf6ers1k3v6ow4lxiy5bd advertise_addr="51.38.30.173:2377" joined=false is_leader=true term=1
INFO satld::cluster: NodeCA bootstrap endpoint listening addr=0.0.0.0:2378
INFO satl_api::server: docker api listening on unix socket socket=/var/run/satl.sock
```

That block is the whole preflight.
Read it as a checklist; every degradation you can still fix appears here, once, and nowhere else:

| Line | Meaning |
| --- | --- |
| `pf_mode="enforce"` on the banner | step 6 took effect. `"check"` means published ports will not work. |
| `linuxulator available` | `linux/*` images can be selected. The other arm names `kldload linux` as the fix. |
| `kern.racct.enable=1 … enforced` | limits are real. The other arm is the `ACCEPTED BUT NOT ENFORCED` warning. |
| `egress interface taken from the default route` | NAT will exist. A warning here means containers get **no outbound connectivity**. |
| `loaded pf anchor anchor=satl/nat` | rules are actually being loaded, not just checked. |
| `cluster state ready … is_leader=true` | this node is a working cluster of one. |
| `docker api listening on unix socket` | the socket is up; `satl` will answer. |

??? note "`cannot measure this node's underlay`, only matters for overlays"

    On a host whose egress interface carries a `/32`, common on cloud VMs, you
    will see this at `ERROR` level:

    ```
    ERROR satld::overlay: cannot measure this node's underlay; no overlay network can be
          programmed until this is fixed ... 51.38.30.173/32 (on ice0) is too small to
          derive a blackhole default remote from ... Set overlay_blackhole in satld.toml
          to an address on this underlay that nothing answers on
    ```

    `if_vxlan` demands a default remote for unknown traffic, and SatL insists it be an address that is *not* a real peer; a real one silently masks a missing forwarding-table entry, which is exactly how an overlay bug survives a two-node test.
    Nothing else is affected: containers, published ports and bridge networks all work.
    Set `overlay_blackhole` when you start using overlay networks.

## 9. Verify

```console
$ satl version
Client:
 Version:           0.1.0
 API version:       1.43

Server:
 Engine:
  Version:          0.1.0
  API version:      1.43 (minimum version 1.24)
  Git commit:       61ebdce
  Built:            2026-08-21T08:22:09Z
  OS/Arch:          freebsd/amd64
  Kernel Version:   15.1-RELEASE-p2

$ satl node ls
ID                            HOSTNAME             STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
1oihjf6ers1k3v6ow4lxiy5bd *   alpha.fredalix.com   Ready    Active         Leader           0.1.0
```

`satl node ls` answering at all is the interesting part: you never ran `swarm init`.
A fresh `satld` initialises a one-member cluster on first boot, so the node is `Ready`, `Active` and `Leader` from the first start.

`install-satl.sh` ends on these two checks and the host ones from steps 1 to 4, as a PASS/FAIL table; `--verify-only` prints it on its own.

If you have the Docker CLI, it works too:

```sh
docker -H unix:///var/run/satl.sock version
```

Next: [Your first container](first-container.md).

Its middle step builds a FreeBSD image, which needs a base image to build `FROM`; [A local registry](registry.md) is the page that puts one on this node, and it is the missing piece behind every `127.0.0.1:5000/satl-test/...` reference on this site.
