# Containers and services

SatL has two front doors, and they lead to the same room.

```sh
satl run -d --name web -p 8080:80 registry.example.com/nginx:1
satl service create --name web -p 8080:80 --replicas 3 registry.example.com/nginx:1
```

The first looks like Docker, the second like Docker Swarm, and underneath there is one model: **every container is a task of a service**.
`satl run` does not take a shortcut around the orchestrator; it creates an anonymous single-replica service and returns the id of its one task.
That task is what `satl ps` lists, what `satl logs` reads, and what `satl inspect` describes.

--8<-- "ops-manager-only.md"

## Why the model is worth knowing

Docker's container is a mutable object with a lifecycle you drive: create, start, stop, start again.
SatL's task is **one-shot and immutable**.
It is created with a complete specification, it runs once, it reaches a terminal state, and that is the end of it.
What survives is the *service*, whose job is to keep the number of running tasks you asked for.

Three visible consequences follow, and they are the ones a Docker user trips
over first.

### `start` on a stopped container is refused

There is no `satl start` verb at all.
Point a Docker CLI at the socket and you get a 409:

```console
$ docker -H unix:///var/run/satl.sock start eager_clarke
Error response from daemon: container eager_clarke has already run and cannot be
started again: a SatL task is one-shot, so create a new container instead (satl run)
```

Re-running a task would mean a *new* task — a new id, and therefore a new container id, which Docker's API has no way to express: it would have to answer "started" and hand back an object under a different identity.
So `docker start` works only on a container that was created and never started, and the way to run that workload again is to create it again.

If what you want is "keep this running", that is a service with a restart policy,
not a container you restart by hand.

### `satl rm` removes the backing service

```sh
satl rm -f web
```

That deletes the service as well as the task.
It has to: leave the service behind and the orchestrator would notice a missing replica within seconds and create a fresh task to fill the slot.
The container you just removed would come back, which is not what anyone means by `rm`.

For a service you created with `satl service create`, use
[`satl service rm`](../reference/cli/service.md#satl-service-rm) — same effect,
named for what it does.

### `satl ps` shows the newest task per slot

A service's replicas are numbered *slots*.
Slot 1 of `web` may have been filled by four successive tasks over its life — a crash, two restarts, a rolling update — and `satl ps` shows you the current one, once.
Retained history is not listed as extra containers, which is why a service that has restarted twice does not look like three containers:

```console
$ satl ps -a
CONTAINER ID   IMAGE                     COMMAND      CREATED      STATUS                  PORTS                  PLATFORM        NAMES
2qw3gxb4uklp   …/freebsd-nginx:latest    ""           2 days ago   Up 2 days               0.0.0.0:8080->80/tcp   freebsd/amd64   web
2blf7rzo7agy   …/alpine                  "uname -a"   2 days ago   Exited (0) 2 days ago                          linux/amd64     eager_clarke
```

The `CONTAINER ID` is the 25-character task id, truncated to 12 as Docker does — not a 64-character hex digest.
`NAMES` is the service's name.
[`PLATFORM`](images.md#which-platform-you-get) is a SatL column, sitting between `PORTS` and `NAMES`.

To see a service's tasks *including* its history, and which node each runs on,
use [`satl service ps`](../reference/cli/service.md#satl-service-ps):

```console
$ satl service ps web
ID             NAME    IMAGE        NODE    DESIRED STATE   CURRENT STATE           ERROR   PORTS
```

`DESIRED STATE` is what the cluster wants; `CURRENT STATE` is what the node last reported.
A task whose desired state is `Running` while its current state is terminal is a task the orchestrator intends to replace — unless its restart budget is spent, which is the one case where that pair is stable rather than transient.

## The states a task goes through

```
NEW → PENDING → ASSIGNED → ACCEPTED → PREPARING → READY → STARTING → RUNNING
                                                             ↓
                                          COMPLETE  /  FAILED  /  SHUTDOWN
```

`PENDING` means the scheduler has not placed it — usually because no node satisfies its constraints or platform.
`PREPARING` is the image pull, the layer clone and the bundle.
`STARTING` covers the gap between "the process is running" and "the process is ready", which is where a [healthcheck](healthchecks.md) lives.
`SHUTDOWN` is an ordered stop; `FAILED` is a task that stopped without being asked to.

Docker's flatter vocabulary is derived from that: `new` through `ready` render as `created`, `starting` and `running` as `running`, `complete`/`shutdown`/`failed` as `exited`, and `rejected`/`orphaned` as `dead`.
`paused` and `restarting` never occur.

Every transition is logged with `from` and `to`, so a task's whole life is one
grep — see [Logs](../config/logging.md#grep-by-identity-not-by-time).

## Running something once

```sh
satl run --rm registry.example.com/alpine:3 uname -a
```

Without `-d`, `satl run` follows the container's log and then exits with the container's own exit code.
`--rm` is performed by the CLI once the container exits, not by the daemon.
`Ctrl-C` kills the container and still reports its code.

`satl wait` also exits with the container's exit code, where `docker wait` always
exits 0 and only prints it — worth knowing if you have a script that tests the
exit status.

## Jobs: services that run to completion { #jobs }

A keep-alive service is replaced when it stops; a **job** is the opposite — it
runs until it finishes, and finishing is the goal:

```sh
satl service create --mode replicated-job --replicas 4 db-migrate:3
satl service create --mode global-job node-inventory:1
```

A replicated job runs `TotalCompletions` slots to a zero exit, at most `--max-concurrent` at a time (both default to the replica count).
A global job runs once per eligible node — and a node that joins or becomes eligible later gets its run too, which makes it the cluster-wide "run this everywhere" tool.

The semantics invert the ones above:

- a task that exits 0 is `Complete` and is **never restarted** — that is the
  success, and `satl service ls` counts it (`REPLICAS` reads completions over
  the goal: `2/4` means two done);
- a task that fails is retried in its slot, within the restart budget —
  `none` is rejected on a job, and `any` is rewritten to `on-failure` at the
  API;
- **`satl service update` on a job re-runs it**: the old run is stopped and every slot starts over on the new spec.
  That, not a rolling update, is the point of updating a job — there is no rollout status.

Two gaps, stated: a retry starts immediately (jobs have no restart-delay
queue), and `Restart.Window` is not honoured — the attempt budget counts the
slot's lifetime, not a rate.

## Keeping something running

```sh
satl run -d --restart always --name web registry.example.com/nginx:1
satl service create --name web --replicas 3 --restart-condition any registry.example.com/nginx:1
```

The restart policy is part of the service, and it is what makes a task's death a non-event: the orchestrator creates a replacement.
Conditions are `none`, `on-failure` and `any` (`satl run` spells them Docker's way: `no`, `on-failure[:max]`, `always`).
`unless-stopped` is rejected outright by the CLI rather than silently treated as `always`.

!!! warning "The restart budget is finite, and a spent one looks like a stuck orchestrator"

    `MaxAttempts` counts replacements per replica *and* per spec version, and the count is derived from the store's task history rather than held in a manager's memory — so it survives a manager restart and a change of leader.
    A crash-looping task therefore stops for good once its attempts are spent:

    ```
    task not restarted task_id=… slot=1 state=failed trigger="task terminated" \
      attempts=2 reason="max restart attempts reached"
    ```

    The task is left in its terminal state with `DESIRED STATE` still `Running`.
    That pair is what "nothing will replace this" looks like in `satl service ps`.
    Pushing a service update starts a fresh budget.

!!! info "Setting a restart delay needs the API"

    `satl service create` carries `--restart-condition` but none of Docker's `--restart-delay`, `--restart-max-attempts` or `--restart-window`.
    A service that needs anything other than the defaults — `any`, 5 s, unlimited — has to be created over the REST API:

    ```sh
    curl -s --unix-socket /var/run/satl.sock -X POST \
      -H 'Content-Type: application/json' --data-binary @spec.json \
      http://localhost/services/create
    ```

    Durations on the wire are nanoseconds, as everywhere in the Docker API, so
    a 30-second delay is `"Delay": 30000000000`.

## Stopping and killing

```sh
satl stop web        # graceful: stop signal, grace period, then SIGKILL
satl kill web        # the same graceful shutdown
```

Both honour the task spec's stop signal and grace period.
`satl stop`'s `-t` is ignored and `satl kill`'s `--signal` is not forwarded, for the same reason in both cases: the grace period and the signal live in the task spec, which is immutable after creation.
Changing them means a new spec — a [service update](rolling-updates.md).

Killing a container of a service with a restart policy gets you a replacement, which is the policy working.
Stopping the *service* is `satl service rm`, or `satl service scale web=0`.

## Names

Service and container names must satisfy SatL's naming rule: `^[a-zA-Z0-9](?:[-_]*[A-Za-z0-9]+)*$`, at most 63 characters.
Letters, digits, hyphens and underscores — **dots are rejected**, where Docker allows them.
The same rule applies to network names.

Omit `--name` and one is generated, Docker-style (`eager_clarke`, `dazzling_torek`).
Task names are `<service>.<slot>.<task id>`, or `<service>.<node id>.<task id>` for a global service, where the node *is* the replica identity.
