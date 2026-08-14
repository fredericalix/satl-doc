# Rolling updates

```sh
satl service update --image registry.example.com/app:2 web
```

That replaces the tasks of `web` in waves, under the policy stored in its spec.
The policy has two halves — how to roll forward, and how to roll back — and each
half takes the same five knobs plus an order. All twelve flags are accepted by
both [`satl service create`](../reference/cli/service.md#satl-service-create) and
[`satl service update`](../reference/cli/service.md#satl-service-update), with
identical meaning and Docker's names, spellings and defaults; they are listed
once in the [update and rollback policy
reference](../reference/cli/service.md#service-policy).

--8<-- "ops-manager-only.md"

## The rule that decides what your flags did

Two sentences, and they are not the same sentence.

!!! success "A flag you omit keeps the value the service already has"

    `satl service update` reads the stored spec, changes only what you named, and
    posts the whole document back. So `satl service update --image … web` does
    not disturb the service's update policy, and `satl service update
    --update-parallelism 2 web` does not disturb its failure action.

!!! warning "Naming any flag of a half fills that half's *other* fields from the defaults"

    A service created with no policy at all, then updated with a lone
    `--update-monitor 30s`, comes out with Docker's defaults for the other five:
    parallelism 1, failure action `pause`, max failure ratio 0, order
    `stop-first`, delay 0.

    That is deliberate rather than sloppy. `Parallelism: 0` means "replace every
    slot at once" to the daemon, and it must never be arrived at by omission —
    which is exactly what would happen if an unnamed field were sent as its zero
    value.

    The *other* half is left alone. Naming an `--update-*` flag does not fill in
    the `--rollback-*` defaults, and vice versa.

The defaults, when a half is filled in: parallelism 1, delay 0, failure action
`pause`, monitor 5 s, max failure ratio 0, order `stop-first`.
`--rollback-failure-action` takes `pause` and `continue` only — a rollback never
rolls back — exactly as Docker's own help documents, though the daemon would
accept `rollback`.

## Watching a rollout

The CLI does not stream progress: `satl service update` prints the id and
returns, like `docker service update -d`. Read the status instead.

```console
$ satl service inspect web | jq '.[0].UpdateStatus'
{
  "State": "updating",
  "StartedAt": "2026-08-12T19:41:02.118Z",
  "Message": "updating: 3 of 6 slots updated"
}
```

`satl service inspect --pretty` prints the spec, not the rollout — for progress,
read `UpdateStatus` from the JSON.

`UpdateStatus.State` moves through `updating` → `completed`, or into `paused`,
`rollback_started`, `rollback_completed`, `rollback_paused`. `Message` is SatL's
own wording and counts slots rather than naming a task, which is what someone
watching a six-replica rollout actually needs:

```
updating: 3 of 6 slots updated
update completed: 6 slots updated
update paused: 2 of 6 tasks failed
rolling back: 2 of 6 tasks failed
rollback completed: 6 slots rolled back
```

`StartedAt` survives the transition into a final state and into a rollback, so it
always means "when this rollout began".

On the leader's log:

```sh
sudo grep -a -E 'rolling update|rolling back|updating slot' /var/log/messages
```

And per slot, `satl service ps web` shows the old task going to `Shutdown` and
the new one climbing through the state machine.

## Timing: the monitor window is part of each batch

!!! info "Six replicas at defaults take at least 30 seconds"

    SwarmKit starts the next batch as soon as the previous task reaches
    `RUNNING`, and keeps watching for failures in the background. SatL makes the
    failure-observation window **part of the batch**: the updater does not start
    the next slot until the current one has been `RUNNING` for `Monitor`.

    With the defaults — `Parallelism: 1`, `Monitor: 5s` — that is 5 seconds per
    slot, so a six-replica update takes at least 30 seconds even if every task
    starts instantly.

    This is what makes the batch health-gated: a task that fails inside its
    window is caught **before the next slot is disturbed**. Combined with
    [health gating `RUNNING`](healthchecks.md#the-first-difference-health-gates-running),
    it is the mechanism behind a rollout that loses no requests.

    To get SwarmKit's pace back, set `Monitor` small. `MaxFailureRatio` behaves
    as documented either way.

`--update-delay` is separate and additional: it is the pause *between* batches,
on top of the monitor window. `--update-order start-first` brings the new task up
before taking the old one down, which needs the service to tolerate two tasks in
one slot briefly — and on the nodes publishing that service's port, means the
[round-robin pool](publishing-ports.md#one-port-many-tasks-the-rule-is-static-the-pool-is-a-table)
briefly holds both.

## A paused update, and how to get out of it

With `--update-failure-action pause` — the default — a rollout that trips
`MaxFailureRatio` stops where it is.

```
UpdateStatus.State: paused
Message:            update paused: 2 of 6 tasks failed
```

The slot it was replacing may be empty, and the updater deliberately does nothing
more for that service: it will not keep feeding replicas to a spec that is
failing. **Everything else keeps working** — scaling, the restart policy, node
eviction — and the paused service's tasks go on being reconciled. Only *further
slots stop being replaced*.

!!! success "Push a corrected spec. Do not remove and recreate."

    Any `satl service update` clears the paused status and starts the rollout
    fresh, so the recovery is:

    ```sh
    satl service update --image registry.example.com/app:1 web
    ```

    `satl service rm` plus a recreate is not needed and costs you the service's
    identity, its allocated published ports and its history.

    The status is cleared on **every** update, not only one that really changes
    the spec — whether the spec changed is decided by the store when the
    transaction commits, so an update posting an identical spec clears the status
    and replaces no task.

With `--update-failure-action rollback` the manager does that for you: it swaps
the spec back to `PreviousSpec` and ends at `rollback_completed`. A rollback that
itself hits the failure ratio *pauses* rather than rolling again, and the same
corrected-spec push gets it moving.

## After an automatic rollback, `PreviousSpec` is empty

!!! warning "This looks like data loss and is not"

    A rollback the manager performs **clears `PreviousSpec` on purpose**. The
    spec that just failed is not a target to return to, so keeping it would only
    offer you a way to redeploy the thing that broke.

    ```console
    $ satl service inspect web | jq '.[0].PreviousSpec'
    null
    ```

    Docker behaves the same way. It is called out here because the field's
    absence, right after something went wrong, reads as the daemon having lost
    the previous specification — and it has not: it has declined to keep a
    failed one.

    `?rollback=previous` therefore has nothing to go back to until the next
    update.

## Rolling back by hand

There is no `satl service update --rollback` flag yet. A manual rollback is a
query parameter on the update endpoint, with the current spec as the body:

```sh
curl -s --unix-socket /var/run/satl.sock -X POST \
  -H 'Content-Type: application/json' --data-binary @spec.json \
  'http://localhost/services/<id>/update?version=<v>&rollback=previous'
```

`rollback` accepts only `previous`. It sets the status to `rollback_started` with
the message `manually requested rollback`, so the updater knows a rollout is
under way and applies `RollbackConfig` rather than `UpdateConfig`.

`--force` — Docker's "restart with no spec change" — is also missing; the
equivalent is bumping `TaskTemplate.ForceUpdate` through the API.

## What else replaces tasks — and one update that does not

A `service update` that changes **only** resource limits or reservations is
the exception to everything above: it does not roll at all. The new values are
applied to the live jails' rctl rules in place — see
[Resizing a live service](resource-limits.md#resizing-a-live-service).

A rolling update is not the only thing that moves containers, and the others do
not go through the update policy:

- **`satl service scale web=6`** creates or removes tasks to reach the count.
  Scaling up places new tasks; scaling down stops the highest slots.
- **A node drained** (`satl node update --availability drain <node>`) gives up
  every task it runs. Eviction from a draining node is the one case where SatL
  ignores the service's restart delay — an operator emptying a node is waiting on
  it — so the replacements are created immediately.
- **A node label change** that stops satisfying a constraint shuts the task down
  and replaces it on a node that does match, at the service's restart delay. So
  editing a label is a placement change that moves running containers.

!!! info "Nothing rebalances afterwards"

    SatL has no rebalancer. Tasks a drain moved stay where they were re-placed:
    a 6-replica service drained off one of three nodes stays 3/3 on the
    survivors, and the returned node runs none of it.

    That is deliberate — moving a healthy task costs an outage for cosmetic
    balance — but it means a node that has been drained and returned stays empty
    until something places work on it. Scaling the service up and back down, or
    any update that replaces its tasks, spreads it again.
