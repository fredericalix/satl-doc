# Linux containers

Most of the container images in the world are Linux images, and SatL runs them.
Not in a VM, not through a second runtime: a `linux/amd64` image becomes an ordinary FreeBSD jail whose processes are executed by the **linuxulator**, the kernel's Linux ABI layer.
Everything else about that container is the same as a native one; it is a task of a service, it gets a VNET jail, an overlay address, published ports, secrets, healthchecks and `rctl` limits, and nothing in SatL takes a different code path for it.

You have almost certainly already run one: the container in [Your first container](../start/first-container.md) is `docker.io/library/alpine`, and Alpine ships no FreeBSD image.

```console
$ satl run docker.io/library/alpine uname -a
Linux 2blf7rzo7agy 5.15.0 FreeBSD 15.1-RELEASE-p2 releng/15.1-n283596-aadd58dddcbc GENERIC x86_64 Linux
```

That is one kernel, wearing two names, which is the honest summary of this whole page.
The emulation is good enough that ordinary userland does not notice, and thin enough that anything reaching for Linux *kernel* machinery finds it missing.
Below is exactly where that line falls, so you can tell in advance whether an image will be happy here.

## Preparing the host

The linuxulator is not loaded by default.
One `rc.conf` line and one service start covers it:

```sh
sysrc linux_enable=YES
service linux start
```

That loads `linux.ko`, `linux64.ko` and `linux_common.ko`, the `linprocfs`, `linsysfs`, `fdescfs` and `pty` modules, and sets `kern.elf64.fallback_brand=3`.

!!! tip "`kern.elf64.fallback_brand=3` is what makes Alpine work"

    An unbranded ELF binary carries no marker saying which ABI it wants, and the fallback brand is the kernel's answer to that question.
    Alpine's `busybox`, and any static musl binary, is exactly that shape.
    With the brand unset (`-1`) glibc images still run and **musl images do not**, which looks like "Alpine is broken" and is really one sysctl.

    `service linux start` sets it only when it is `-1`, so check it rather than assuming:

    ```sh
    sysctl compat.linux.osrelease kern.elf64.fallback_brand
    ```

`satld` probes for the emulation at startup and tells you what it found, once, in the log:

```
INFO satld::node: linuxulator available; linux/* images may be selected osrelease=5.15.0
```

The other arm of that line names `kldload linux` as the fix.
A node that runs only FreeBSD images needs none of this; the capability is per node, and the scheduler treats it as one.

## How a task ends up being a Linux task

SatL picks the platform when it resolves the image, in this order:

1. the platform you asked for with `--platform os/arch[/variant]`, which must exist in the index;
2. **`freebsd/<host arch>`**: a native jail, and always preferred;
3. **`linux/amd64`**, when the node has the linuxulator available;
4. otherwise an error naming what the index does offer.

So you never ask for emulation: you get it when there is no FreeBSD image and the host can do it.
The choice is recorded rather than inferred, and it is a column of its own in both `satl images` and `satl ps`:

```console
$ satl ps -a
CONTAINER ID   IMAGE                             COMMAND      CREATED         STATUS                    PORTS   PLATFORM       NAMES
1kqlz3n8p4bd   docker.io/library/alpine          "uname -a"   2 minutes ago   Exited (0) 2 minutes ago           linux/amd64    eager_clarke
```

In a mixed cluster the capability travels with the node: a Linux task scheduled onto a node without the emulation is refused there with a message naming the node, rather than started and left to die.
See [the troubleshooting entry](../trouble/containers.md#linux-image-rejected) for both rejection texts.

## What the container is given

A Linux jail needs a Linux-shaped filesystem view, and SatL generates the whole mount set itself.
Every one of them is performed from the *host*, by `ocijail`, when the container is created (a jailed process cannot mount anything itself), so this list is all of it, and nothing inside the container can add to it:

| Mount | Filesystem | Why |
| --- | --- | --- |
| `/proc` | `linprocfs` | Linux's procfs layout: `/proc/self/maps`, `/proc/cpuinfo`, working `ps` |
| `/sys` | `linsysfs` | `bus`, `class`, `dev`, `devices`, `kernel`, and nothing else |
| `/dev` | `devfs`, ruleset 5000 | the jail-safe device set, plus `shm` |
| `/dev/fd` | `fdescfs` (`linrdlnk`) | Linux-style `/dev/fd` symlink semantics |
| `/dev/shm` | `tmpfs`, `mode=1777` | POSIX shared memory, which glibc expects to exist |
| `/tmp` | `tmpfs`, `mode=1777` | per-container scratch, gone with the container |

??? note "Why SatL owns devfs ruleset 5000"

    FreeBSD's stock jail ruleset (4) hides devfs's global `shm` directory, and devfs supports no `mkdir` at all, so creating the `/dev/shm` mountpoint fails, and the container fails with it:

    ```
    filesystem error: in create_directory: Operation not supported [".../dev/shm"]
    ```

    Ruleset 5000 is the classic jail set (`devfsrules_hide_all`, `unhide_basic`, `unhide_login`) plus `shm` unhidden.
    `satld` installs it at every startup, because a ruleset lives in the kernel only until reboot.
    It is the same "own your own namespace" habit as SatL's `satl/*` pf anchors, and it is why the device list inside a container is the jail set and not your host's disks.

## musl and glibc both work

The folklore is that the linuxulator targets glibc and that musl breaks on it.
On FreeBSD 15.1 that is not reproducible, and both were exercised deliberately:

| Image | libc | What was verified |
| --- | --- | --- |
| Alpine 3.24 | musl, dynamic **and** static `busybox` | `sh`, `uname`, `ps`, `/proc` introspection, `apk add` over TLS, and `busybox-extras` `httpd` serving HTTP |
| Ubuntu 24.04 | glibc 2.39 | `bash`, `apt-get` (`main`), `dpkg`, `perl`, `getconf` |

The caveat worth keeping: musl and glibc exercise different syscall paths, so if an Alpine image misbehaves in a way that looks like SatL's fault, retry the same job on a glibc image before reporting it.
That one comparison saves most of the guessing.

## Where the emulation stops

This is the part to read before you plan a deployment around a Linux image.
None of it is a bug list; it is the shape of a jail, and a jail is not a Linux container.

!!! warning "No cgroups, no PID namespace, so no systemd"

    There is no cgroup filesystem at all: `linsysfs` provides only `bus class dev devices kernel`, so there is not even a `/sys/fs` to hang a mountpoint on, and `/proc/cgroups` does not exist.
    A FreeBSD jail also has no PID namespace, so a container's entrypoint keeps its host PID and is **never PID 1**.

    An image whose entrypoint is an init system is therefore **refused when the task is created**, not started and left to fail:

    ```
    container '1kql…': image runs "/sbin/init" as PID 1; FreeBSD jails provide no
    PID namespace or cgroups, so systemd/init cannot run (it dies silently under
    the linuxulator). Use an image with a plain foreground entrypoint
    ```

    The rejection is up front because runtime detection would be useless: systemd 255 answers `systemd --version` happily and then exits 1 **with no output whatsoever** when asked to run as `systemd --system`.
    The only trace is a `dmesg` line about an unsupported `prctl` option.
    A one-sentence refusal is a better experience than a container that vanishes in silence.

    What to use instead: an image whose entrypoint is the service itself.
    That is how official images for nginx, Postgres, Redis, Node and most others are already built.

!!! warning "`/proc/meminfo` reports the host's memory, whatever the limit says"

    `linprocfs` reflects the machine, not the jail, so `/proc/meminfo` and `/proc/cpuinfo` inside a Linux container describe the whole host.
    `--memory` and `--cpus` are still enforced (they are `rctl(8)` rules and they are real), but a runtime that sizes itself by reading `/proc` cannot see them.

    In practice that means a JVM picking a heap, a Go program reading `GOMAXPROCS`, or Node deciding a pool size will all aim at the host's figures and get killed at the limit they never saw.
    Size them **absolutely**, not as a percentage: the percentage forms (`-XX:MaxRAMPercentage`, and every runtime's "detect the container" logic) read the cgroup limits that are not there, so they compute a fraction of the host and land in the same place.

    ```sh
    satl run --memory 512m -e JAVA_TOOL_OPTIONS=-Xmx384m …
    satl run --memory 512m -e GOMEMLIMIT=400MiB --cpus 2 -e GOMAXPROCS=2 …
    ```

    [Resource limits](resource-limits.md) covers how the limits themselves work.

A shorter list of things that simply are not there, each of which fails cleanly rather than mysteriously:

- **netlink, `io_uring`, cgroupfs**: anything using them fails; expect `unsupported prctl option` lines in `dmesg` from programs probing for capabilities they cannot get.
- **OFD file locks** return `EINVAL`, which occasionally surprises a database or a lockfile library.
- **SysV IPC is off** in a jail by default, and PostgreSQL cannot even `initdb` without it.
  Opt in per container with the labels `satl.jail.sysvshm=new` and `satl.jail.sysvsem=new`.
- **`uname -r` reports `5.15.0`**, from `compat.linux.osrelease`, not the FreeBSD version.
  glibc keys behaviour off that number, so raise it if you must and never lower it.
- **`satl build` builds FreeBSD images only.**
  It is the FreeBSD image tool, deliberately; pull Linux images from a registry, or build them on a Linux machine and push them there.

## When something does not work

Two dedicated troubleshooting entries carry the symptom/check/fix form:

- [The task is `REJECTED` and names the linuxulator or an init system](../trouble/containers.md#linux-image-rejected): the host is missing the modules, or the image wants an init system.
- [The container exits immediately and `satl logs` is empty](../trouble/containers.md#silent-exit): usually a missing kernel feature, and `dmesg` is where it says so.

One diagnostic worth knowing about before you file anything: the kernel can log every Linux syscall it does not implement.

```sh
sysctl compat.linux.debug=3        # then reproduce, and read dmesg
```

Each unimplemented call is reported once, which turns "the container just dies" into a specific missing syscall.
That output is the single most useful attachment to a bug report about a Linux image; see [Before you report a problem](../trouble/getting-help.md).

If you find an image that ought to work here and does not, we would genuinely like to know.
Emulation gaps are the kind of thing that gets fixed once and helps everyone after you.
