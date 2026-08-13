# Containers

Every container in SatL is a task of a service, so the question "why is this
container not running?" is nearly always answered in one of three places: the
scheduler could not place the task, the node refused to prepare it, or it started
and died. All three write their reason into the task, which is what
`satl service ps`'s `ERROR` column shows and what `satl ps` renders as an exited
container.

Start here:

```sh
satl service ps <service>                      # DESIRED STATE, CURRENT STATE, ERROR
sudo grep -a 'task_id=<the id>' /var/log/messages
```

## `no suitable node (…)` in the `ERROR` column { #no-suitable-node }

**Symptom**

```console
$ satl service ps web
ID       NAME    IMAGE   NODE  DESIRED STATE  CURRENT STATE  ERROR
1kql…    web.1   nginx         Running        Pending        no suitable node (scheduling constraints not satisfied on 3 nodes)
```

**Check.** The parenthesis is the whole diagnosis. The wordings are fixed:

| Explanation | The filter that rejected every node |
| --- | --- |
| `no nodes in the cluster` | nothing reached the scheduler at all |
| `N nodes not available for new tasks` | every node is `Down`, `pause`d or `drain`ing |
| `insufficient resources on N nodes` | the task's CPU/memory **reservations** do not fit anywhere |
| `scheduling constraints not satisfied on N nodes` | `--constraint` matches no node |
| `unsupported platform on N nodes` | no node runs an OS/arch the image publishes |
| `host-mode port already in use on N nodes` | a host-mode published port collides |

More than one reason appears when different nodes failed differently, most
frequent first, separated by `; `.

```sh
satl node ls                                   # availability and status
satl node inspect <node> --pretty              # labels, platform, resources
satl service inspect <service>                 # constraints, reservations, image
```

**Reading.** The counts are nodes examined since the last successful placement,
so "3 nodes" on a three-node cluster means every node was tried and rejected.
`not available for new tasks` counts drained and paused nodes as well as down
ones — a node you paused an hour ago is still refusing work.

**Fix.** Whichever the explanation names: relax the constraint, return a node to
`--availability active`, lower the reservation, or push an image built for a
platform the cluster runs.

??? note "Why this happens"

    Placement runs a fixed filter pipeline per task, in order: availability,
    resource reservations, constraints, image platform, host-mode ports, and the
    per-node replica cap. A node that passes every filter clears the counters,
    so the explanation always describes the nodes examined since the last
    success rather than an all-time tally. Only *reservations* participate —
    `--memory`/`--cpus` are limits, enforced on the node by `rctl(8)`, and never
    influence where a task lands.

    A task that no node accepts is not failed: it stays `Pending` and is retried
    on every pass, so fixing the cause is enough to make it run. Nothing has to
    be recreated.

## The task is `REJECTED` and names the linuxulator or an init system { #linux-image-rejected }

**Symptom** — one of

```
container '1kql…': image runs "/sbin/init" as PID 1; FreeBSD jails provide no
PID namespace or cgroups, so systemd/init cannot run (it dies silently under
the linuxulator). Use an image with a plain foreground entrypoint
```

```
container '1kql…' needs the linuxulator but it is not available on this host
(probe `/sbin/sysctl -n compat.linux.osrelease` failed with exit code 1;
stderr: "sysctl: unknown oid 'compat.linux.osrelease'"). Load the linux kernel
modules (linux_enable="YES" in rc.conf, then `service linux start`) or schedule
the task on a linux-capable node
```

**Check**

```sh
kldstat -m linux
sysctl compat.linux.osrelease kern.elf64.fallback_brand
sudo grep -a 'linuxulator' /var/log/messages | tail -5
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `sysctl: unknown oid 'compat.linux.osrelease'` | the linuxulator modules are not loaded on this node |
| `compat.linux.osrelease: 5.15.0`, `kern.elf64.fallback_brand: 3` | the host is ready; the rejection was about the entrypoint |
| `kern.elf64.fallback_brand: -1` | glibc images may run and **musl/static ones will not** — Alpine's busybox is an unbranded SYSV ELF |

**Fix.** For the host, `linux_enable="YES"` in `rc.conf` plus
`service linux start` — that loads `linux.ko`, `linux64.ko`, `linprocfs`,
`linsysfs`, `fdescfs`, `pty` and sets the fallback brand. For the image, use one
whose entrypoint is a plain foreground process.

??? note "Why an init entrypoint is refused up front"

    A FreeBSD jail has no PID namespace, so the entrypoint keeps its host PID
    and is never PID 1, and there is no cgroup filesystem at all — `linsysfs`
    provides only `bus class dev devices kernel`, so there is not even a
    `/sys/fs` to hang a mountpoint on.

    Runtime detection is useless here, which is the whole reason for the
    up-front rejection: systemd 255 under the linuxulator answers
    `systemd --version` happily and then **exits 1 with no output at all** when
    run as `systemd --system`. The only trace is in `dmesg`
    (`linux: jid N pid M (systemd): unsupported prctl option 27|39|47`). A
    container that dies instantly and silently is a far worse experience than a
    task rejected with a sentence.

    Both musl (Alpine) and glibc (Ubuntu) images otherwise work on FreeBSD 15.1
    — the folklore that the linuxulator needs glibc is not reproducible here.

## The container exits immediately, and `satl logs` is empty { #silent-exit }

**Symptom.** The task reaches `RUNNING` and goes `FAILED` (or `COMPLETE`)
within a second, with nothing in the logs.

**Check**

```sh
satl inspect <container> | grep -i -A3 'State'
sudo dmesg | tail -40
sudo grep -a 'task_id=<id>' /var/log/messages
```

**Reading.** Three shapes, distinguishable from `dmesg`:

| Signal | Cause |
| --- | --- |
| `linux: … unsupported prctl option …` | a Linux image using syscalls the emulation does not implement |
| nothing anywhere, image expects `/sys/fs/cgroup` or `/proc/cgroups` | there is no cgroup filesystem; the application decided it could not run |
| the daemon log carries an `ocijail` command line and its stderr | a real runtime failure — read the argv and the stderr, they are both there |

**Fix.** Depends entirely on the third column. What is worth knowing before you
start: `/proc/meminfo` and `/proc/cpuinfo` inside a Linux container report the
**host's** resources, so JVM- and Go-style automatic sizing sees the whole
machine; OFD file locks return `EINVAL`; and anything needing netlink, cgroupfs
or `io_uring` fails. An Alpine image misbehaving is worth retesting against a
glibc image before blaming SatL — musl exercises different syscall paths.

## `--memory` and `--cpus` do nothing { #limits-not-enforced }

**Symptom.** A container comfortably exceeds the cap it was given, and nothing
kills or throttles it.

**Check**

```sh
sysctl kern.racct.enable
rctl -h jail:<container id>
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `kern.racct.enable: 0` | accounting is off; the limits were accepted and enforced by nothing — the reason is recorded in the task's status message and in the [startup banner](daemon.md#degraded) |
| `kern.racct.enable: 1`, `rctl` prints rules | enforcement is live; read the next paragraph before calling it broken |
| `kern.racct.enable: 1`, `rctl` prints nothing | the rules were not installed — a real defect; collect [what Getting help asks for](getting-help.md) |

**Fix**

```sh
echo 'kern.racct.enable=1' >> /boot/loader.conf   # sysrc(8) rejects dotted names
shutdown -r now
sysctl kern.racct.enable                          # expect 1
```

It is a boot-time tunable: it cannot be switched on at runtime.

??? note "What the two flags actually do on FreeBSD"

    | Flag | Rule | Behaviour |
    | --- | --- | --- |
    | `--memory` | `jail:<id>:memoryuse:sigkill=<bytes>` | the process is **killed** when the jail's resident set exceeds the cap — the closest equivalent to a Linux OOM kill. `memoryuse:deny` would be silently useless: RSS is not a deniable resource in the kernel, yet `rctl` accepts the rule (measured — a 64 MB `deny` cap allocated 200 MB without complaint) |
    | `--cpus` | `jail:<id>:pcpu:deny=<percent>` | the scheduler **throttles** the jail toward the cap. Accounting is a decaying average, so the cap is approached rather than imposed instantly: a fixed CPU-bound workload measured 4.4 s unlimited and 10.5 s at `pcpu:deny=20`, converging further on longer runs |

    So "it went over the cap briefly" is expected for `--cpus` and unexpected
    for `--memory`. Rules are removed when the container is removed.

## `container … has already run and cannot be started again` { #start-refused }

**Symptom**

```console
$ satl start web
Error response from daemon: container 1kql… has already run and cannot be
started again: a SatL task is one-shot, so create a new container instead
(satl run)
```

(and the same from `docker start` against SatL's socket, as a 409).

**Reading.** Not a bug and not a transient state. A container here **is** a
task, and a task is one-shot and immutable: re-running it would mean a new task,
which means a new container ID — something Docker's API has no way to express.
`start` therefore only works on a container that was created and never started.

**Fix.** `satl run` again, or — if you wanted the thing to come back on its own —
create it as a service with a restart policy. See
[Differences from Docker](../docker-differences.md).

## `… is not supported by SatL: …` on create { #rejected-options }

**Symptom**

```console
$ satl run --privileged nginx
Error response from daemon: HostConfig.Privileged is not supported by SatL:
jails have no privileged mode
```

**Reading.** The rejected set is fixed and each entry names its reason:

| Option | Reason given |
| --- | --- |
| `Privileged` | jails have no privileged mode |
| `CapAdd`/`CapDrop` | Linux capabilities do not exist on FreeBSD |
| `SecurityOpt` | seccomp/apparmor/selinux do not exist on FreeBSD |
| `Devices` | device mapping is governed by the jail devfs ruleset |
| `CgroupParent` | resource limits are enforced by rctl(8), not cgroups |
| `Sysctls` | per-jail sysctls are not configurable |
| `Ulimits` | use Memory/NanoCpus, which map to rctl(8) rules |
| `PidMode`/`IpcMode`/`UTSMode`/`UsernsMode` | namespace sharing does not exist on FreeBSD jails |
| `ShmSize` | jails have no `/dev/shm` tmpfs |
| `CpuShares`/`CpuQuota`/`CpusetCpus` | use NanoCpus, which maps to an rctl(8) pcpu limit |
| `MemorySwap` | FreeBSD accounts swap separately from memory |
| `Mounts` | use `Binds` (`src:dst[:ro]`) or `Tmpfs` |

**Fix.** Remove the flag, or use the alternative the message names. There is no
mode in which these are accepted and ignored, and that is deliberate: **a
half-honoured isolation flag is a security trap** — a caller who asked for
`--security-opt` and got a 200 would reasonably believe something was enforced.

## The container's dataset is still there a minute after `satl rm` { #dataset-busy }

**Symptom**

```
ERROR … task_step{step="remove" task_id=1k7g… service=ovl-a}:
  satl_agent::controller: task cleanup step failed step="destroy-rootfs"
  error=`/sbin/zfs destroy -r zroot/satl/containers/1k7g…` failed with exit
  code 1; stderr: "cannot unmount '/var/db/satl/containers/1k7g…': pool or
  dataset is busy"
```

**Check**

```sh
sudo grep -a "has not finished dying"               /var/log/messages
sudo grep -a "deferring it to the periodic dataset" /var/log/messages
sudo grep -a "periodic sweep destroyed a container" /var/log/messages
jls -d -h name dying | grep <task id>
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the task id appears under `jls -d -h name dying` | **normal.** Its prison is still dying; the dataset will go when it does |
| a deferral line, then a reclamation line for the same `task_id` | **normal, already resolved.** Expect roughly 60–100 s end to end |
| a deferral line and no reclamation line minutes later, with no dying prison | a different problem — check `mount -v \| grep <task id>` for vnodes and report it |

**Fix.** Wait. `satld` handles this by itself in two stages: the removal retries
for up to 30 s keyed on the prison's existence, then hands the dataset to a
sweep that runs every 20 s and destroys it as soon as the jail is gone. No
restart, no intervention.

??? note "Why a rootfs stays busy, and why nothing shows a holder"

    `jail_remove(2)` does not destroy a prison: it moves it to `DYING` and it
    stays there until its last reference goes. A prison holds its root directory
    as an active vnode **inside the container's own ZFS filesystem**, so
    `unmount(2)` returns `EBUSY` — and `zfs destroy` unmounts before it
    destroys, which is why the message says *cannot unmount* rather than *cannot
    destroy*. It is a VFS refusal, not a ZFS one.

    That reference belongs to no process and no file, so `fstat -f <rootfs>`
    reports **zero** open files, `procstat -a -f` finds no process, `mount -p`
    shows no submount, and `ps -axo jid` shows nothing in the jail. Only
    `jls -d -h name dying` sees it — and it has to be asked exactly that way:
    plain `jls -d` lists live jails too, so "`jls -d` printed something" means
    nothing at all.

    **What takes the time is TCP, not the jail.** A VNET prison cannot be
    dismantled while its network stack still holds protocol control blocks, and
    a TCP connection outlives the process that owned it. Measured, same image,
    same teardown:

    | What the container did | Busy for |
    | --- | --- |
    | nothing but `sleep` | 0.00 s |
    | one connection, completed and closed before teardown | 0.00 s |
    | one connection still open | **57.75 s** |
    | still open, `net.inet.tcp.msl=2000` inside the jail | 4.00 s |
    | still open, but the jail has no VNET | 0.00 s |

    That is 2 × MSL exactly, twice. Note that `net.inet.tcp.*` is
    VNET-virtualised: lowering it on the host changes nothing for a jail, which
    starts from the compile-time defaults.

## A task with a healthcheck never reaches `RUNNING`, then fails { #unhealthy-task }

**Symptom.** `satl ps` shows `Up 2 seconds (health: starting)` for a while, and
then the task is `FAILED` with a streak and an exit code in its error, and a
replacement appears.

**Check**

```sh
satl inspect <container> | grep -i -A20 'Health'
satl service ps <service>
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `health: starting` for longer than you expect | correct: the first probe runs one `interval` **after** the container starts, never at t=0 |
| `Health check exceeded timeout (2s)` in the log | the probe outlived its timeout; recorded as exit code `-1`, exactly as Docker words it |
| repeated non-zero exits, then the task fails | `retries` **consecutive** failures outside the start period end the task |
| `State.Health` missing entirely | you asked a node that is not running the task — health is node-local and never enters the store |

**Fix.** Lengthen `start_period` for a slow starter, or fix the probe. What you
cannot do is leave it unhealthy and running.

??? note "Why health ends the task here and not in Docker"

    Two deliberate differences, both of which follow from a container being a
    task of a service:

    - **health gates the state machine.** A task with a healthcheck is not
      reported `RUNNING` until a probe passes; it stays `STARTING`. That is the
      reason the feature exists: the DNS responder only answers with `RUNNING`
      tasks, and a rolling update only promotes on observed `RUNNING`, so
      neither can send traffic to a container that has not passed a probe.
    - **an unhealthy task is stopped and `FAILED`**, and the restart supervisor
      replaces it under the service's restart policy. Docker leaves an unhealthy
      container running and its `--restart` never reacts to health at all.

    Two smaller ones worth knowing: the image's own `HEALTHCHECK` is **not**
    inherited (only the spec's is honoured), and during the start period SatL
    probes on `min(interval, 5s)` so a slow starter is not held back by a long
    interval.

## The image will not pull { #pull-fails }

**Symptom** — one of

```
refusing plain-HTTP registry "registry.example.com": only localhost/127.0.0.1
may be contacted without TLS
```

```
no matching platform for freebsd/amd64, linux/amd64 (emulation) in
registry.example.com/app:1; available: [linux/arm64, windows/amd64]
```

```
registry registry.example.com: authentication failed for app: … (WWW-Authenticate: …)
```

**Check**

```sh
satl pull <reference>
sudo grep -a -E 'registry|manifest|platform' /var/log/messages | tail -20
```

**Reading.** The three shapes are unrelated: a registry reachable only over
plain HTTP is refused unless it is loopback; a platform list that contains
nothing this node can run is an image problem, and the message prints exactly
what the registry offered; an auth failure quotes the challenge it got.

**Fix.** Give the registry TLS (or run it on `127.0.0.1`), push an image built
for `freebsd/amd64` or `linux/amd64`, or fix the credentials. Platform selection
prefers `freebsd/amd64|arm64` from a manifest list and falls back to
`linux/amd64`; `satl ps` and `satl images` show the resolved platform in their
`PLATFORM` column.
