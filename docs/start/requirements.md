# Requirements

Read this before you type anything.
Two entries below need a reboot or a package the machine may not have, and one of them (`kern.racct.enable`) cannot be turned on at runtime at all.

## The checklist

| What | Why | If it is absent |
| --- | --- | --- |
| **FreeBSD 15 on amd64** | SatL is built and run on 15.1-RELEASE and on 15-CURRENT. It uses jail, VNET, ZFS, pf, rctl and `if_vxlan` directly, through `sysctl`, `ifconfig`, `pfctl`, `zfs` and `ocijail`. | Untested. Nothing is deliberately tied to one release, and nothing older has been run — see [Which FreeBSD](#which-freebsd). |
| **A ZFS pool, and a root dataset for SatL** | ZFS is not one storage driver among several: a layer *is* a dataset, applying a layer is snapshot + clone, and a container's writable layer is a clone. | `satld` **refuses to start**, with the command to fix it in the error. See below. |
| **root** | `satld` creates jails, ZFS datasets and network interfaces, and loads pf anchors. | The daemon cannot install its devfs ruleset, and every jail creation fails at `/dev`. |
| **`ocijail`** — `pkg install ocijail` | SatL implements no runtime. It generates an OCI spec and drives the `ocijail` binary. | Every task fails at the create step. Nothing fails at startup, which makes it a confusing way to find out. |
| **A Rust toolchain** — `pkg install rust` | **Only if you build from source.** The [package](install.md#5-install-satl) needs no toolchain at all. | Nothing, unless you are building — then see the version note below. |
| **pf, loaded and enabled** | pf *is* SatL's data path: NAT for container egress, `rdr` for published ports. | Containers get no outbound connectivity and no published port is redirected. |
| **Three anchor lines in `/etc/pf.conf`** | SatL only ever writes inside `satl/*`, and an anchor that is not declared is never evaluated. | The daemon loads its rules into anchors nothing consults. Everything looks fine and nothing works. |
| **`kern.racct.enable=1` in `/boot/loader.conf`, then a reboot** | Resource accounting is a boot-time tunable; `rctl(8)` rules cannot be installed without it. | `--memory` and `--cpus` are **accepted and silently not enforced**. `satld` warns at startup; nothing else complains, ever. |
| **IP forwarding** — `gateway_enable=YES` | Container traffic is *routed* between the bridge and the egress interface. | Containers have **no outbound connectivity**, while inbound published ports still answer — which is the most misleading failure mode in the whole system. |
| **Ports 2377/tcp, 2378/tcp, 4789/udp between nodes** | Only if you will cluster. 2377 is the mTLS control plane, 2378 the CA bootstrap a first-time joiner needs, 4789 the VXLAN data plane. If you will also use [encrypted overlays](../use/networks.md#encrypted): ESP (IP protocol 50) as well — no UDP on 4790–4999. | Joins hang or fail; overlay traffic goes nowhere while every interface reports itself healthy. |

## Which FreeBSD { #which-freebsd }

**15.1-RELEASE and 15-CURRENT, on amd64.**
Both have been run: the single-host material on this site and the three-node cluster material were exercised on each.

There is no version check anywhere in SatL — nothing reads `kern.osrelease` and compares it, and nothing is conditionally compiled — so "15.1" throughout this site is a statement about where a thing was *measured*, never about what the daemon will accept.
That cuts both ways, and it is worth being plain about which:

- an older FreeBSD is not refused, it is simply untested, and the interfaces
  SatL drives (`if_vxlan`'s forwarding table, `rctl`, VNET, the `pf` anchors,
  `ocijail`) are exactly the ones that changed most recently;
- **amd64 is not a preference, it is the only architecture built.**
  There is no arm64 package and no cross-build.

Two limits that follow the platform rather than the release, both listed in full under [what SatL does not do](../reference/out-of-scope.md#platform):

- **IPv4 only.**
  SatL assigns no IPv6 addresses to containers, and IPv6 subnets on network
  creation are refused rather than accepted and ignored.
- **ZFS is mandatory**, which is the next section.

## ZFS: what "mandatory" means

`satld` checks for its root dataset before doing anything else and stops if it
is not there:

```
ZFS root dataset 'zroot/satl' does not exist; create it with:
zfs create -o mountpoint=/var/db/satl zroot/satl
```

The default is `zroot/satl` because that is what a stock FreeBSD root-on-ZFS install gives you.
**If your pool is not named `zroot`**, the dataset name is different and you must say so in `satld.toml`:

```console
$ zpool list
NAME    SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
zroot   893G   182G   711G        -         -    13%    20%  1.00x    ONLINE  -
```

```toml
# /usr/local/etc/satl/satld.toml, only if your pool is not `zroot`
zfs_root = "tank/satl"
```

SatL creates the five child datasets it needs — `raft`, `images`, `layers`, `containers`, `volumes` — under that root on first start.
You only create the root.

The `state_dir` (default `/var/db/satl`) should be the root dataset's mountpoint.
`satld` warns at startup when the two differ, rather than refusing: they *can* legitimately differ, but they usually differ by accident.

## The Rust version, checked on a real host

Only relevant if you are building from source — installing
[`satl-freebsd.pkg`](install.md#5-install-satl) skips this entirely.

SatL's workspace declares `rust-version = "1.96"` and `edition = "2024"`.
The FreeBSD package gives you exactly that, and no more:

```console
$ pkg install rust
$ rustc --version
rustc 1.96.1 (31fca3adb 2026-06-26) (built from a source tarball)
```

!!! warning "There is no margin here"

    `pkg`'s `rust` is 1.96.1 against a floor of 1.96.
    That works today, and it will keep working — but if your `pkg` repository is a snapshot older than this one, `cargo build` fails at the manifest with a `rustc 1.x is not supported by the following package` error before it compiles a line.
    Check `rustc --version` **before** the install steps, not during them.

    `rustup` is the escape hatch if your repository is behind.

## The reboot, and deferring it

`kern.racct.enable` is the only entry on the checklist that needs a reboot, and it is the only one you can reasonably defer.
If you do, know exactly what you are trading:

```
WARN satld::node: kern.racct.enable=0: rctl(8) rules cannot be installed, so --memory and
     --cpus are ACCEPTED BUT NOT ENFORCED. Add kern.racct.enable=1 to /boot/loader.conf
     and reboot to enable resource limits.
```

`satl run --memory 512m` will not fail.
The API will not complain.
The reason is recorded in the task's status message and in that one startup line, and nowhere else.
Everything except resource limits works identically.

--8<-- "loader-conf.md"

`sysrc(8)` is for `rc.conf` and rejects dotted names, which is why these are appended directly rather than set with `sysrc`.
Verify after the reboot with `sysctl kern.racct.enable`, expecting `1`.
When it is on, `satld` says so:

```
INFO satld::node: kern.racct.enable=1; rctl(8) resource limits are enforced
```

!!! danger "Do not set `rctl_enable=YES` in `rc.conf`"

    That loads static rules from `/etc/rctl.conf` at boot.
    SatL adds and removes its own rules per container; the two do not need each other and the static file will fight you.

## Nice to have

- **A container registry you can reach.**
  SatL pulls from any OCI registry.
  `satl build` exists, but it builds FreeBSD images into one node's store — for anything else, or to share an image across nodes, you need a registry.
  [First container](first-container.md) deals with this honestly.
- **The `docker` CLI**, if you have it.
  `docker -H unix:///var/run/satl.sock version` works, and it is a useful independent check that the API surface is what it claims to be.

Next: [Install](install.md).
