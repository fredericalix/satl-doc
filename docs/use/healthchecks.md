# Healthchecks

A healthcheck is a command SatL runs inside your container, on a timer, to decide whether it is actually serving.
The semantics are Docker's, taken from Docker's own implementation rather than from its documentation.
What differs is what health *does*, and it does considerably more here, because a container is a task.

## Defining one

`satl run` and `satl service create` carry no healthcheck flags, so a probe comes from the API.
A Docker CLI pointed at SatL's socket is the easy path:

```sh
docker -H unix:///var/run/satl.sock service create --name web \
  --health-cmd 'curl -fsS http://localhost/ || exit 1' \
  --health-interval 10s --health-timeout 2s --health-retries 3 \
  --health-start-period 30s \
  registry.example.com/nginx:1
```

or the spec directly:

```json
{
  "Name": "web",
  "TaskTemplate": {
    "ContainerSpec": {
      "Image": "registry.example.com/nginx:1",
      "Healthcheck": {
        "Test": ["CMD-SHELL", "curl -fsS http://localhost/ || exit 1"],
        "Interval": 10000000000,
        "Timeout": 2000000000,
        "Retries": 3,
        "StartPeriod": 30000000000
      }
    }
  },
  "Mode": { "Replicated": { "Replicas": 3 } }
}
```

Durations are nanoseconds on the wire, as everywhere in the Docker API.

`CMD` execs the argument vector directly; `CMD-SHELL` goes through `/bin/sh -c`;
`NONE`, and any unrecognised first element, means no probe, with a warning,
exactly as Docker does.

!!! warning "Probe the task's own address; there is no `localhost`"

    A SatL jail's `lo0` carries only `::1`; `127.0.0.1` is unassigned, so the Docker-style `curl http://localhost/` above connects to nothing.
    Read the task's own address off its interface instead, and note the minimal `freebsd-runtime` base has no `awk`, so the parsing is pure shell:

    ```
    ip=$(/sbin/ifconfig | while read a b rest; do [ "$a" = inet ] && { echo "$b"; break; }; done)
    fetch -qo /dev/null http://$ip:8080/health || exit 1
    ```

    In a compose file, every literal `$` is written `$$`.
    A working example is in the [Node.js + MariaDB tutorial](../start/app-node-mariadb.md).

!!! warning "The image's `HEALTHCHECK` is not inherited"

    Only the healthcheck in the service or container spec is honoured.
    An image that declares `HEALTHCHECK` in its Dockerfile gets **no probe**, and its task reaches `RUNNING` on start, where Docker, and Docker Swarm, would inherit it and gate on it.

    Docker's "inherit from the image" marker, `Test: [""]`, therefore means "no
    healthcheck" here.

## How a probe is judged

The probe runs as `ocijail exec` inside the task's jail, with the container's own environment, working directory and user.
Its exit status is the result: **0 is healthy, anything else is a failure**.

| Field | Default | Meaning |
| --- | --- | --- |
| `Interval` | 30 s | between probes |
| `Timeout` | 30 s | a probe that outlives this is a failure |
| `Retries` | 3 | **consecutive** failures needed for `unhealthy` |
| `StartPeriod` | 0 | grace window at the beginning |

Those are Docker's defaults, and they are what you get, unless the service
[publishes a port](#publishing-a-port-tightens-the-defaults), which changes three
of them.

- The **first probe runs one interval after the container starts**, never at
  t = 0.
- `Retries` consecutive failures make it unhealthy; **a single success resets the
  streak** and makes it healthy immediately.
- Failures are ignored while the status is `starting` *and* the probe began inside `StartPeriod`.
  Once a container has been healthy once, `StartPeriod` no longer protects it.
- A probe that cannot be run at all, or that outlives its timeout, is recorded as
  exit code `-1` with Docker's own wording (`Health check exceeded timeout (2s)`),
  and the probe process is `SIGKILL`ed rather than abandoned, because a probe
  left running inside the jail can [keep the container's rootfs
  busy](../config/state.md#the-container-dataset-that-outlives-its-container)
  long after the container is gone.
- `State.Health.Log` keeps the last 5 results, each with up to 4096 bytes of
  output.

??? note "`Healthcheck.StartInterval` is not supported"

    Docker's `start_interval` (a shorter probe interval during the start period) has no field in SatL's service spec.
    The behaviour it exists for is hard-wired instead: while the container has never yet been healthy, SatL probes on `min(interval, 5 s)`, which is Docker's own default for the field.
    So a slow starter is not held back by a long `interval`, and an interval already shorter than 5 s is never slowed down.

## Publishing a port tightens the defaults

A service that [publishes a port](publishing-ports.md) is the one case where the probe is not just a status light: it is what takes a dead backend out of the traffic.
`pf` is a packet filter, and a `round-robin` redirect pool never probes what it redirects to, so a container that stops answering keeps receiving its share of the connections until something one layer up removes it.
That something is the healthcheck.

So where a service publishes a port, and **only** there, SatL applies tighter
defaults than Docker's:

| Field | Docker, and SatL elsewhere | SatL, published service |
| --- | --- | --- |
| `Interval` | 30 s | **5 s** |
| `Timeout` | 30 s | **3 s** (or `min(30 s, interval)` if you set the interval) |
| `Retries` | 3 | **2** |
| `StartPeriod` | 0 | 0; unchanged, it is a property of your boot time |

They are applied **field by field, and only where you left the field unset**.
An explicit value always wins, so Docker's behaviour is available by asking for it (`Interval: 30000000000`, `Timeout: 30000000000`, `Retries: 3`).

The tighter timeout is not cosmetic.
The prober runs one probe at a time, so an oversized timeout does not overlap probes; it stretches the detection bound to `retries × (interval + timeout)` with nothing in the configuration looking wrong.
A hanging probe on 5 s/30 s/2 takes 70 s to a verdict, not 10 s.

!!! note "The values are written into the stored spec, not applied at probe time"

    Docker applies its defaults as the prober runs and leaves the stored spec exactly as you posted it, zeroes included.
    SatL writes the effective numbers into the spec at create and update, so `satl service inspect` shows the values the prober will use rather than a `0` that means something else, and logs one line naming them:

    ```sh
    sudo grep -a 'tighter health probe defaults' /var/log/messages
    # … applied to a published service … name=web published=8080->80/tcp \
    #   applied=interval=5s timeout=3s retries=2
    ```

    The consequence to know is that they then look **explicit**: removing the
    published port later does not restore Docker's 30 s, because nothing can tell
    your `5s` from ours.

### What it buys, and what it costs

Measured end to end on one node, nginx with a file-existence probe and the marker then removed: **9.97 s** from the probe starting to fail to the task's address being out of the pf redirect pool.
The same run with Docker's defaults would be about 90 s of traffic into a dead backend.

!!! warning "Here, leaving the pool and being killed are the same event"

    Docker leaves an unhealthy container running and merely takes it out of the load balancer.
    SatL [stops it](#the-second-difference-an-unhealthy-task-is-replaced).
    So tightening detection ninefold makes **replacement** ninefold more eager too.

    A long GC pause, a wedged dependency, a probe that blips under load: what used
    to need 90 s of failure to cost you a container now needs 10 s. That is how a
    restart storm starts where the operator only wanted the traffic to stop, and
    the tighter the probe, the smaller the hiccup that triggers it.

Two things bound it.
`Retries` is what separates a blip from a sustained failure; 2 retries at 5 s means the probe must fail for **10 s continuously**, and a single success resets the streak.
And the restart budget bounds the loop: `RestartPolicy.MaxAttempts` counts replacements per replica and per spec version and [survives a leadership change](../trouble/cluster.md#restart-budget-spent), so a service created with it stops replacing instead of churning for ever.
The default is unlimited, so on a service that matters, set it.

### Trading detection latency for stability

A verdict takes up to `retries + 1` cycles of `interval + timeout`, one cycle more than `retries`, because a container stops answering *between* two probes and the probe already in flight may have passed a moment before.
The stop that follows takes up to `stop_grace_period` (10 s by default), and a failed `pfctl` load is repaired by the next port pass within 5 s:

| `interval` | `retries` | sustained failure needed | worst case out of the pool |
| --- | --- | --- | --- |
| 5 s (both unset) | 2 | 10 s | 3 × (5+3) + 10 + 5 = 39 s |
| 5 s (unset) | 4 | 20 s | 5 × (5+3) + 10 + 5 = 55 s |
| 10 s (explicit) | 3 | 30 s | 4 × (10+10) + 10 + 5 = 95 s |
| 30 s (Docker's, explicit) | 3 | 90 s | 4 × (30+30) + 10 + 5 = 255 s |

The third column is what protects a healthy-but-slow container; the fourth is how long a dead one keeps taking traffic.
**Raising `retries` is usually the better knob**: it lengthens the failure a blip has to sustain without slowing the probe down.
Raising `interval` slows detection *and* slows the first probe after a start, and note that setting the interval explicitly also moves the timeout to `min(30 s, interval)`, so set `timeout` too if your probe is slow.

### A published service with no probe at all is a warning

At create and update, in the `Warnings` array and in the log:

```console
$ satl service create --name web -p 8080:80 registry.example.com/nginx:1
service web publishes 8080->80/tcp and has no healthcheck: its tasks are published
as soon as the jail starts, before the workload can answer, and stay published
while a dead container keeps its share of the traffic
```

It is a warning and not a refusal, because a service with no probe is legitimate; you may health-check the port from a load balancer instead.
It is just usually not what the publisher meant.
The measurement behind it: the redirect was installed 5 ms after `jail start`, against the 250 ms the nginx in that jail needed to bind its port.

!!! danger "`satl run -p` is always in that state, and cannot be fixed"

    The container API reads **no healthcheck at all**, Docker's `--health-cmd` and friends are accepted by the JSON parser and dropped, and `satl run` has no flag to set one.
    So a published container is never health-gated: its redirect appears as soon as the jail starts and is never removed while the jail stays up.

    `satl run -p` is deliberately *not* warned about, because there would be no way to comply, and a warning nobody can act on is how warnings that matter get ignored.
    Publish through a **service** if you want the gate.

## The first difference: health gates `RUNNING`

!!! success "Nothing routes to a container that has not passed a probe"

    A task with a healthcheck is **not reported `RUNNING` until a probe has passed**.
    It sits in `STARTING`, which renders through the Docker API as state `running` with `Status` reading:

    ```
    Up 2 seconds (health: starting)
    ```

    Two things read `RUNNING` and only `RUNNING`: the embedded DNS responder,
    which answers a service name with its running tasks' addresses, and the
    rolling updater, which promotes a batch on observed `RUNNING`.

    So neither can hand traffic to a container that has not yet said it is ready.
    **This is what makes a [rolling update](rolling-updates.md) lose no requests**: not the update policy, which only controls pacing.
    Without a healthcheck, a task is `RUNNING` the moment its process starts, and a rollout will happily route to a container that is still opening its database connections.

    Docker has no equivalent: its container is `running` the moment it starts,
    whatever its health.

`StartPeriod` is therefore the budget for "how long may this take to become ready".
It is worth setting honestly.

## The second difference: an unhealthy task is replaced

!!! warning "Docker leaves an unhealthy container running. SatL stops it."

    `Retries` consecutive failures outside the start period **end the task**: it
    is stopped with its own stop signal and grace period, reported `FAILED` with
    the streak and the last probe's exit code in `Status.Err`, and the restart
    supervisor replaces it under the service's restart policy.

    A container that never becomes healthy therefore *fails* rather than sitting at `starting` for ever.
    `StartPeriod` is the only grace it gets.

This is SwarmKit's behaviour rather than an invention, and it is the reason a healthcheck here is a control input and not a status light.
Two practical consequences:

- **A flaky probe is a restart loop.**
  A probe that fails three times in a row during a garbage collection pause will kill a container that was fine.
  Set `Timeout` and `Retries` for the worst case you are willing to tolerate, not the typical one.
- **A probe that depends on something else is a cascade.**
  `curl` against a database that is briefly down will take the whole service down with it, and the restart budget will then be spent replacing containers that were never at fault.
  Probe what *this* container can answer for.

## Health is node-local, and not in the store

```console
$ satl inspect web | jq '.[0].State.Health'
{ "Status": "healthy", "FailingStreak": 0, "Log": [ … ] }
```

`State.Health` appears **only when the node answering the request is the one running the task.**
A worker reports health for its own tasks.
A manager reports it for tasks placed on itself and **omits it entirely for tasks placed elsewhere**, where Docker, being single-host, always has it.

That is invariant, not an oversight: health never enters the Raft store, because a worker holds only ephemeral executor state.
Two follow-ons:

- **`satl service ps` shows no health**, and neither do `Task` documents from `GET /tasks`.
  That matches `docker service ps`, which shows none either.
- **Health is not persisted.**
  After a `satld` restart, an adopted running task starts again at `starting` and is re-probed, with the failing streak back at zero.
  Its history is gone; its container was never disturbed.

To see the health of a task running elsewhere, ask the node that runs it:
`satl service ps <service>` names it, over that node's own socket, or read that
node's log:

```sh
sudo grep -a 'task_id=<task id>' /var/log/messages
```
