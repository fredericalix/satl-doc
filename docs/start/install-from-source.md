# Install from source

The [package](install.md#5-install-satl) is the ordinary way in, and if you have no reason to prefer this one, prefer that one.
Two reasons make this page the right path.
The first: you want a fix that is not in a release yet.
The second: you want to **build the package yourself**, for a cluster, for a host whose FreeBSD differs from the published build's, or simply because you would rather install something you compiled.

The host preparation is identical either way.
Only the step that puts the binaries on disk is different, so this page replaces [step 5 of Install](install.md#5-install-satl) and nothing else on it.

## What this needs that the package does not

Everything on the [Requirements](requirements.md) checklist still applies (ZFS, `ocijail`, pf, the boot-time tunables) plus one thing the package deliberately avoids needing:

**A Rust toolchain.**
`pkg install rust`, and the version matters more than usual.

!!! warning "There is no margin on the Rust version"

    The workspace declares `rust-version = "1.96"` and `edition = "2024"`, and FreeBSD's `rust` package gives you 1.96.1, one patch release above the floor.
    There is no `rust-toolchain.toml` pinning anything, so cargo enforces that floor when it parses the manifest: a `pkg` repository older than this one fails the build before compiling a line, with `rustc 1.x is not supported by the following package`.

    Check `rustc --version` **before** you start, not during.
    `rustup` is the escape hatch if your repository is behind.
    The measured version is on [Requirements](requirements.md#the-rust-version-checked-on-a-real-host).

**`make` means FreeBSD `make(1)`.**
The Makefile uses bmake's `!=` shell assignment and `${.CURDIR}`; GNU make does not parse it.
On FreeBSD that is simply `make`, which is the only platform this builds on anyway.

!!! info "There is no cross-build, and no other architecture"

    SatL is built for FreeBSD on amd64 and nothing else; see [Which FreeBSD](requirements.md#which-freebsd) and [the platform notes](../reference/out-of-scope.md#platform).
    Nothing in the source is conditionally compiled for a platform; it simply drives FreeBSD interfaces directly.
    You build it on a FreeBSD host, on the architecture you will run it on.

## Get the source

```sh
git clone https://github.com/fredericalix/satl
cd satl
```

## Compile

```sh
make build          # debug build of satl + satld
make release        # release build, into target/release
```

Both build the whole workspace: eighteen crates, of which two produce binaries: `satl` (the CLI) and `satld` (the daemon).
`make build` is for iterating; everything below that matters uses `release`.

## Install it

```sh
sudo make install
```

Four files, and they are the same four the package installs, in the same places:

| Path | What |
| --- | --- |
| `/usr/local/bin/satl` | the CLI |
| `/usr/local/sbin/satld` | the daemon |
| `/usr/local/etc/rc.d/satld` | the rc.d service |
| `/usr/local/etc/satl/satld.toml.sample` | a commented sample config |

`PREFIX` moves all four (`make install PREFIX=/opt/satl`), and `DESTDIR` stages them somewhere else entirely without touching the live prefix.

!!! note "`sudo make install` compiles a second time, on purpose"

    It builds into `target/install`, not `target/release`, so the two do not share artifacts and an install after a `make release` compiles again.

    That is a deliberate trade.
    `sudo make install` building into `target/release` used to leave **root-owned artifacts** there, and every later unprivileged `make check` or `make build` then failed with `Operation not permitted` until the tree was chowned back.
    Keeping root's build products in a directory of their own costs disk and compile time, and buys never having to think about it.

    The alternative (an `install` target that does not build at all) would silently install whatever stale binary happened to be lying around, which is worse than either.

!!! danger "This installs a sample, not a config"

    `make install` writes `satld.toml.sample`.
    It does **not** create `satld.toml`, and a missing config file is legal; the daemon runs on built-in defaults, where `pf_mode` is `check` and **no published port is ever redirected**, with nothing logged as an error.

    This catches essentially every first install, from source or from the package.
    [Install step 6](install.md#6-write-satldtoml-do-not-skip-this) is the fix and it is not optional.

## Build a package

```sh
make package
```

That writes `dist/satl-<version>.pkg`, `dist/satl-0.1.0.pkg` at the current version, installable on any host with `pkg add ./satl-0.1.0.pkg` and **no repository needed**.

It depends on `release`, so what gets packaged is `target/release`, and the staging layout mirrors `make install` exactly: the same four files, the same modes, the same paths.
A package install and a source install put the same bytes in the same places.

Three values are substituted into the package manifest as it is built, and knowing where each comes from is the difference between a package that installs on your nodes and one that does not:

| Value | Read from |
| --- | --- |
| the version | `version =` in the workspace `Cargo.toml` |
| the package ABI | `pkg config ABI` on **the host running `make package`** |
| the `ocijail` dependency version | `pkg rquery %v ocijail` on **the host running `make package`** |

!!! warning "The package is stamped with the building host's ABI and its `ocijail`"

    Both of the last two come from the machine you build on, not from anything in the source tree.
    So a package built on one FreeBSD version carries that version's ABI, and it carries a dependency on exactly the `ocijail` version that host's package repository advertised at build time.

    Build on a host of the same FreeBSD version as the nodes you will install on.
    A node whose repository offers a different `ocijail` will argue about the dependency rather than install cleanly.

    This is also the one step in the whole build that reaches the network: `pkg rquery` needs a configured repository.
    An offline machine can `make release` and `make install`, but not `make package`.

`DISTDIR` moves the output (`make package DISTDIR=/tmp/pkgs`).
`dist/` is not tracked by git.

!!! tip "One package, every node"

    This is the reason to build a package rather than run `make install` on each machine.
    Build once, `scp` the `.pkg` around, `pkg add` on each node; a cluster wants the same build everywhere, and mixing versions across nodes is not a configuration SatL is tested in.

## Verify what you built

There is no CI on this project.
Opening a pull request runs nothing (no GitHub Actions, no checks tab), because the build and the tests need FreeBSD with ZFS, jails, pf and `ocijail`, which no hosted runner offers.
`make check` on a FreeBSD host is the only gate there is, and running it is yours to do.

```sh
make check              # fmt, clippy -D warnings, the workspace test suite
sudo make integration   # root-only: jails, ZFS, pf, network interfaces
make cluster-test       # the three-node scenario suite
```

`make check` also enforces the SPDX headers: every source file carries its licence identifier on line 1, or line 2 after a shebang.
Fixture files, captured command output that parsing tests diff byte for byte, are data rather than source, and stay headerless.

`make integration` runs the tests that are `#[ignore]`-gated because they need root and a real host, and it runs them **one at a time**.
That is not caution about speed: these tests create and audit global host state (jails, network interfaces, ZFS datasets, pf anchors), and check for leftovers when they finish.
Run in parallel, one test's interfaces turn up in another test's leftover audit and fail it spuriously.
It also builds into `target/integration`, for the same root-ownership reason `install` builds into `target/install`.

## Then configure it, exactly as the package path does

Nothing after this point is different from a package install.
Go back to [Install](install.md) and do steps 1–4 (storage, forwarding, pf anchors, boot tunables) if you have not, then 6 onwards:

1.
   [write `satld.toml`](install.md#6-write-satldtoml-do-not-skip-this): the step that decides whether published ports work;
2.
   [enable and start](install.md#7-enable-and-start) the service;
3.
   [read the startup lines](install.md#8-read-the-startup-lines) as a checklist; every degradation you can still fix appears there once and nowhere else;
4.
   [verify](install.md#9-verify) with `satl version` and `satl node ls`.

## Updating a source install

```sh
git pull
make check
sudo make install
service satld restart
```

Restarting the daemon does **not** stop the node's containers; they are jails, and they keep running while `satld` is away; the startup reconciliation re-adopts them.
What a restart does and does not touch is [in the service page](../config/service.md#what-a-restart-does-and-does-not-touch).

!!! danger "There is no supported upgrade path between versions"

    Nothing versions the on-disk state, and nothing has been tested across versions.
    Rebuilding from a newer commit and restarting is what this section describes; it is not a promise that the state a previous build wrote is still understood.
    See [no upgrade path](../reference/out-of-scope.md#no-upgrade) and [Project status](../about/status.md).

    On a cluster, that applies per node and the nodes are not independent; read [Clustering](../cluster/index.md) before rebuilding one manager of three.

## Starting over

```sh
make clean
```

`cargo clean`, so it removes `target/` entirely, including `target/install` and `target/integration`.
Anything you have already produced in `dist/` survives it.

Next: [Your first container](first-container.md).
