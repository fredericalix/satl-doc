# Healthchecks

A healthcheck is a command SatL runs inside your container, on a timer, to
decide whether it is actually serving. The semantics are Docker's, taken from
Docker's own implementation rather than from its documentation. What differs is
what health *does* — and it does considerably more here, because a container is a
task.

## Defining one

`satl run` and `satl service create` carry no healthcheck flags, so a probe comes
from the API. A Docker CLI pointed at SatL's socket is the easy path:

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
`NONE` — and any unrecognised first element — means no probe, with a warning,
exactly as Docker does.

!!! warning "The image's `HEALTHCHECK` is not inherited"

    Only the healthcheck in the service or container spec is honoured. An image
    that declares `HEALTHCHECK` in its Dockerfile gets **no probe**, and its task
    reaches `RUNNING` on start — where Docker, and Docker Swarm, would inherit
    it and gate on it.

    Docker's "inherit from the image" marker, `Test: [""]`, therefore means "no
    healthcheck" here.

## How a probe is judged

The probe runs as `ocijail exec` inside the task's jail, with the container's own
environment, working directory and user. Its exit status is the result: **0 is
healthy, anything else is a failure**.

| Field | Default | Meaning |
| --- | --- | --- |
| `Interval` | 30 s | between probes |
| `Timeout` | 30 s | a probe that outlives this is a failure |
| `Retries` | 3 | **consecutive** failures needed for `unhealthy` |
| `StartPeriod` | 0 | grace window at the beginning |

- The **first probe runs one interval after the container starts**, never at
  t = 0.
- `Retries` consecutive failures make it unhealthy; **a single success resets the
  streak** and makes it healthy immediately.
- Failures are ignored while the status is `starting` *and* the probe began
  inside `StartPeriod`. Once a container has been healthy once, `StartPeriod` no
  longer protects it.
- A probe that cannot be run at all, or that outlives its timeout, is recorded as
  exit code `-1` with Docker's own wording (`Health check exceeded timeout (2s)`)
  — and the probe process is `SIGKILL`ed rather than abandoned, because a probe
  left running inside the jail can [keep the container's rootfs
  busy](../config/state.md#the-container-dataset-that-outlives-its-container)
  long after the container is gone.
- `State.Health.Log` keeps the last 5 results, each with up to 4096 bytes of
  output.

??? note "`Healthcheck.StartInterval` is not supported"

    Docker's `start_interval` — a shorter probe interval during the start period
    — has no field in SatL's service spec. The behaviour it exists for is
    hard-wired instead: while the container has never yet been healthy, SatL
    probes on `min(interval, 5 s)`, which is Docker's own default for the field.
    So a slow starter is not held back by a long `interval`, and an interval
    already shorter than 5 s is never slowed down.

## The first difference: health gates `RUNNING`

!!! success "Nothing routes to a container that has not passed a probe"

    A task with a healthcheck is **not reported `RUNNING` until a probe has
    passed**. It sits in `STARTING`, which renders through the Docker API as
    state `running` with `Status` reading:

    ```
    Up 2 seconds (health: starting)
    ```

    Two things read `RUNNING` and only `RUNNING`: the embedded DNS responder,
    which answers a service name with its running tasks' addresses, and the
    rolling updater, which promotes a batch on observed `RUNNING`.

    So neither can hand traffic to a container that has not yet said it is
    ready. **This is what makes a [rolling update](rolling-updates.md) lose no
    requests** — not the update policy, which only controls pacing. Without a
    healthcheck, a task is `RUNNING` the moment its process starts, and a rollout
    will happily route to a container that is still opening its database
    connections.

    Docker has no equivalent: its container is `running` the moment it starts,
    whatever its health.

`StartPeriod` is therefore the budget for "how long may this take to become
ready". It is worth setting honestly.

## The second difference: an unhealthy task is replaced

!!! warning "Docker leaves an unhealthy container running. SatL stops it."

    `Retries` consecutive failures outside the start period **end the task**: it
    is stopped with its own stop signal and grace period, reported `FAILED` with
    the streak and the last probe's exit code in `Status.Err`, and the restart
    supervisor replaces it under the service's restart policy.

    A container that never becomes healthy therefore *fails* rather than sitting
    at `starting` for ever. `StartPeriod` is the only grace it gets.

This is SwarmKit's behaviour rather than an invention, and it is the reason a
healthcheck here is a control input and not a status light. Two practical
consequences:

- **A flaky probe is a restart loop.** A probe that fails three times in a row
  during a garbage collection pause will kill a container that was fine. Set
  `Timeout` and `Retries` for the worst case you are willing to tolerate, not
  the typical one.
- **A probe that depends on something else is a cascade.** `curl` against a
  database that is briefly down will take the whole service down with it, and
  the restart budget will then be spent replacing containers that were never at
  fault. Probe what *this* container can answer for.

## Health is node-local, and not in the store

```console
$ satl inspect web | jq '.[0].State.Health'
{ "Status": "healthy", "FailingStreak": 0, "Log": [ … ] }
```

`State.Health` appears **only when the node answering the request is the one
running the task.** A worker reports health for its own tasks. A manager reports
it for tasks placed on itself and **omits it entirely for tasks placed
elsewhere** — where Docker, being single-host, always has it.

That is invariant, not an oversight: health never enters the Raft store, because
a worker holds only ephemeral executor state. Two follow-ons:

- **`satl service ps` shows no health**, and neither do `Task` documents from
  `GET /tasks`. That matches `docker service ps`, which shows none either.
- **Health is not persisted.** After a `satld` restart, an adopted running task
  starts again at `starting` and is re-probed, with the failing streak back at
  zero. Its history is gone; its container was never disturbed.

To see the health of a task running elsewhere, ask the node that runs it —
`satl service ps <service>` names it — over that node's own socket, or read that
node's log:

```sh
sudo grep -a 'task_id=<task id>' /var/log/messages
```
