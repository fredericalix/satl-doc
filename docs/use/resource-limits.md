# Resource limits

```sh
satl run -d --memory 512m --cpus 1.5 registry.example.com/app:1
satl service create --limit-memory 512m --limit-cpu 1.5 registry.example.com/app:1
```

Two flags, and they behave less alike than their names suggest. SatL has no
cgroups to work with — there are none on FreeBSD — so both are `rctl(8)` rules
scoped to the container's jail, and `rctl` is a different tool with different
semantics.

## They need `kern.racct.enable=1`, and it is a boot-time tunable

Resource accounting cannot be switched on at runtime. FreeBSD's GENERIC kernel
ships with it off (`RACCT_DEFAULT_TO_DISABLED`), because it costs per-process
bookkeeping in the kernel.

--8<-- "loader-conf.md"

```sh
shutdown -r now
sysctl kern.racct.enable          # expect 1
```

!!! danger "Without it, `--memory` and `--cpus` are accepted and silently unenforced"

    The daemon does not refuse to start, and it does not refuse the flags. It
    accepts them, records the reason in the task's status message, and runs the
    container with no limit at all. A container you believe is capped at 512 MB
    will happily take the machine.

    `satld` says which mode it is in, once, at startup. **Check that line before
    you trust a limit.**

    ```
    INFO satld::node: kern.racct.enable=1; rctl(8) resource limits are enforced
    ```

    ```
    WARN satld::node: kern.racct.enable=0: rctl(8) rules cannot be installed, so
         --memory and --cpus are ACCEPTED BUT NOT ENFORCED. Add kern.racct.enable=1
         to /boot/loader.conf and reboot to enable resource limits.
    ```

    ```sh
    sudo grep -a 'kern.racct.enable' /var/log/messages | tail -1
    ```

!!! failure "Do not set `rctl_enable="YES"` in `rc.conf`"

    That is a different thing entirely: it loads static rules from
    `/etc/rctl.conf` at boot. SatL adds and removes its own rules per container,
    and does not want a static ruleset alongside them. Setting the loader tunable
    is all that is needed.

## What the two flags actually do

| Flag | rctl rule | Behaviour |
| --- | --- | --- |
| `--memory` / `--limit-memory` | `jail:<id>:memoryuse:sigkill=<bytes>` | the process is **killed** when the jail's resident set exceeds the cap |
| `--cpus` / `--limit-cpu` | `jail:<id>:pcpu:deny=<percent>` | the scheduler **throttles** the jail toward the cap |

### `--memory` kills

This is the closest FreeBSD equivalent of a Linux cgroup OOM kill, and it is not
a throttle, a soft limit, or a reclaim hint. Cross the cap and the process gets
`SIGKILL`. A container that occasionally spikes past its limit will die, and its
service's restart policy will replace it — which will look like a crash loop with
no message, because from inside the container nothing happened.

??? note "Why not `memoryuse:deny`?"

    Because it would be silently useless. RSS is not a deniable resource in the
    FreeBSD kernel — there is no allocation to refuse at the right moment — yet
    `rctl` accepts the rule without complaint. Measured: a 64 MB `deny` cap
    allocated 200 MB and nothing objected. A rule that is accepted and does
    nothing is worse than no rule, so SatL uses the one that works.

### `--cpus` throttles, over time

`pcpu:deny` makes the scheduler hold the jail toward the cap, and rctl's
accounting is a decaying average — so the limit is *approached*, not imposed
instantly. A short burst above it is normal and expected.

Measured on a fixed CPU-bound workload: 4.4 s unlimited, 10.5 s at
`pcpu:deny=20`, converging further on longer runs. Do not benchmark a CPU limit
with a one-second job and conclude it does not work.

`--cpus` takes fractions: `0.5`, `1.25`, `2`.

## Inspecting the live rules

```sh
rctl -h jail:<container id>
```

The rules are named for the jail, which is named for the task, which is the
container id you see in `satl ps`. They are removed when the container is
removed.

## `/proc/meminfo` inside a Linux container shows the host

!!! warning "Anything that auto-sizes from `/proc` sees the whole machine"

    Under the linuxulator, `/proc/meminfo` and `/proc/cpuinfo` are `linprocfs`
    views of the **host's** resources. They know nothing about the jail's rctl
    limits.

    A JVM with `-XX:MaxRAMPercentage`, a Go runtime sizing `GOMAXPROCS`, a Node
    process reading `os.totalmem()`, or anything else that auto-sizes from those
    files, will size itself for the whole machine and then be `SIGKILL`ed the
    moment it grows into the `--memory` cap it never saw.

    Set the limits explicitly inside the container instead:

    ```sh
    satl run -d --memory 512m \
      -e JAVA_TOOL_OPTIONS='-Xmx384m' \
      -e GOMAXPROCS=2 \
      registry.example.com/app:1
    ```

    This is a platform limit, not a bug that can be detected at runtime. Closing
    it would need something like an `LD_PRELOAD` shim rewriting those files
    per-jail, which SatL does not do.

## What is refused rather than half-honoured

Docker's other resource knobs are rejected with a 400, never accepted and
ignored:

`CpuShares`, `CpuQuota`, `CpusetCpus` (use `NanoCpus`, which is what `--cpus`
sets), `MemorySwap` (FreeBSD accounts swap separately from memory), `Ulimits`,
`ShmSize` (jails have no `/dev/shm` tmpfs of Docker's kind), `CgroupParent`,
`Sysctls`, and `Resources.Limits.Pids` on a service spec.

The rationale is the same one that runs through the whole API surface: a
half-honoured isolation option is a security trap, and a resource option that
silently does nothing is a capacity plan built on a false number.
