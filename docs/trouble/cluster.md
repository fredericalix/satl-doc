# The cluster

Managers, workers, leadership, and the places where what the CLI prints is not what the cluster is doing.
The first entry on this page is the one that misleads people during an incident, so it is first.

## `satl node ls` names a dead node `Leader` { #stale-manager-status }

**Symptom**

```console
$ satl node ls
ID       HOSTNAME  STATUS  AVAILABILITY  MANAGER STATUS  ENGINE VERSION
1ab2…    node1     Down    Active        Leader          0.1.0
2cd3…    node2     Ready   Active        Reachable       0.1.0
3ef4…    node3     Ready   Active        Reachable       0.1.0
```

and the cluster is answering writes perfectly well, which it could not do with
a dead leader.

**Check.**
Ask each node's own log which one believes it holds leadership:

```sh
{ for f in $(ls -tr /var/log/messages.*.bz2 2>/dev/null); do bzcat "$f"; done
  cat /var/log/messages; } 2>/dev/null | grep -a satld |
  awk '/starting satld/                                      { last = "" }
       /leadership gained: starting the leader-only components/ { last = "leader"   }
       /leadership lost: stopping the leader-only components/   { last = "follower" }
       END { print (last == "" ? "unknown" : last) }'
```

Run it on every manager.
Exactly one running daemon should print `leader`.
The `starting satld` reset matters: these lines outlive a restart, so a node that *was* leader before it was killed still carries its `leadership gained`.

**Reading**

| Outcome | Meaning |
| --- | --- |
| exactly one node prints `leader` | that is the real leader, whatever the column says |
| every node prints `unknown` | you are reading only the live file; [the line was rotated](reading-the-log.md#rotation) |
| two nodes print `leader` | one of them has not processed its loss yet; re-read in a few seconds |

**Fix.**
There is nothing to fix on the cluster; **the column is stale, not the cluster.**
`Node.ManagerStatus` is written when the cluster forms and is never refreshed on a leadership change, so after a leader dies every node goes on calling it `Leader`, permanently, including after it rejoins as a follower.
No API surface reports the live Raft leader either.

!!! danger "Never pick a node to act on from that column"

    During an incident this reads as "the leader is down, that is why writes fail" when in fact a new leader was elected seconds later and writes are fine.
    And a runbook that restarts "the leader" from that column restarts the wrong daemon, which is exactly why SatL's own cluster tests read the log instead.

    Prove leadership by its consequences: a write that commits (a node label set and read back) tells you a leader exists; the log tells you which node it is.
    `STATUS` (`Ready`/`Down`) *is* maintained and can be trusted.

## `cannot …: this cluster has no raft leader right now` { #no-raft-leader }

**Symptom**

```console
$ satl service scale web=8
Error response from daemon: cannot update the service: this cluster has no raft
leader right now; writes are refused until one is elected
```

Reads keep working.
Only writes are refused.
The daemon-side wording is `no raft leader is known right now, so the mutation cannot be forwarded; the cluster is electing or has lost quorum`.

**Check**

```sh
satl node ls                                # how many managers are Ready?
sudo grep -a -E 'raft leadership|leadership (gained|lost)' /var/log/messages | tail -20
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the message clears within seconds | an ordinary election. Nothing to do |
| a majority of managers is `Down` | **quorum is lost.** Managers alone form quorum; two managers plus a worker tolerate *no* manager failure |
| every manager is up and no election completes | look for TLS refusals in the log: expired or untrusted certificates stop replication dead ([TLS and joins](tls.md#expired-certs)) |

**Fix.**
Bring managers back.
Promotion applies live, so promoting a third manager before taking one down is a viable emergency move, and it is the only reason quorum arithmetic is worth thinking about in advance.

## `This node is not a swarm manager.` { #not-a-swarm-manager }

**Symptom**

```console
$ satl service ls
Error response from daemon: This node is not a swarm manager. Worker nodes can't
be used to view or modify cluster state. Please run this command on a manager
node or promote the current node to a manager.
```

**Reading.**
You are on a worker.
A worker holds no replicated store, so it has nothing to answer with.
This is Docker's own message, verbatim, with Docker's own 503.

What is refused on a worker: `satl service`, `satl node`, `satl network`
(**all** of it; a SatL network is a store object even when its driver is
`bridge`), `satl swarm` inspection and token rotation, and **container
lifecycle mutations**: create, start, stop, kill, rm, and therefore `satl run`.

What still works and shows that node's own containers: `satl ps`, `satl inspect`,
`satl logs`, `satl wait`, `satl exec`, `satl images`, `satl pull`, `satl volume`.

**Fix.**
Run the command on a manager, or `satl node promote <node>`, which applies live, with the same daemon pid and without disturbing running containers.

??? note "Why container mutations are refused where Docker allows them"

    A Docker worker still runs standalone containers.
    SatL has none: every container is a task of a service, and a task mutation is a store write that a worker cannot propose.
    Run it on a manager and the scheduler places the task, possibly on the very worker you were standing on.

## A node reads `Down` { #node-down }

**Symptom.**
`satl node ls` shows `Down`, and the tasks that were on it appear elsewhere.

**Check**

```sh
sudo grep -a -E 'node marked down|agent session' /var/log/messages | tail -20
```

on the managers, and on the node itself:

```sh
service satld status
sudo grep -a 'agent session' /var/log/messages | tail -20
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `node marked down: heartbeat failure` on a manager | the node's dispatcher session TTL expired. Heartbeat is 5 s and the TTL is 3 × that, so about 15 s of silence |
| `agent session ended` / `agent session lost; reconnecting` on the node | the node is alive and cannot reach a manager, network, or TLS |
| the daemon is stopped on the node | expected: **stopping `satld` does not stop its containers**, so they keep running as strays until it returns |

**Fix.**
Restore the node.
When it comes back, its agent reaps the containers whose tasks were evicted in the meantime, and its own view converges.

!!! note "Its containers were still serving the whole time"

    A node going `Down` means the managers stopped hearing from it, not that its workloads stopped.
    That is why `satl service ls` can legitimately read `8/6` for a while; see the next entry.

## `satl service ls` says `8/6` { #replica-count }

**Symptom.**
A 6-replica service reports more running replicas than it has.

**Reading.**
Correct, and temporary.
The `REPLICAS` column counts observed `Running` tasks against wanted.
A task on a node that stopped answering keeps its last reported `Running` state (nothing can report otherwise, and the node-down-to-orphaned timer is 24 h), while the manager has already moved its desired state on and scheduled a replacement.

A **live** task is one whose desired state is `Running` *and* whose current state is `Running`.
Counting observed `Running` alone says "8 running" for a 6-replica service with one node down, which is not what anyone means.

**Fix.**
Nothing.
The count settles when the node returns (its strays are reaped) or when the orphan timer expires.

## `satl service ps <name>` prints an empty table and exits 0 { #empty-service-ps }

**Symptom**

```console
$ satl service ps ghost
ID    NAME    IMAGE    NODE    DESIRED STATE    CURRENT STATE    ERROR    PORTS
$ echo $?
0
```

**Reading.**
`ghost` may not exist.
The task list is filtered by service name and an unknown name simply matches nothing, so the daemon answers `200` with an empty list and the CLI prints the header.
Docker errors here (`no such service: ghost`).

**Fix.**
Check the name against `satl service ls` before concluding a service has no tasks.
An empty table means "no tasks matched", not "this service has no tasks".

## A rolling update stopped halfway and says `paused` { #update-paused }

**Symptom**

```console
$ satl service inspect web | grep -A3 UpdateStatus
"UpdateStatus": { "State": "paused", "Message": "update paused: 2 of 6 tasks failed", … }
```

One slot may be empty, and nothing further happens.

**Check**

```sh
sudo grep -a -E 'rolling update|rolling back|updating slot' /var/log/messages | tail -20
satl service ps <service>                       # what did the failed tasks say?
```

**Reading.**
With the default `--update-failure-action pause`, a rollout that trips `MaxFailureRatio` stops where it is, on purpose: the updater will not keep feeding replicas to a spec that is failing.
Everything else about the service keeps working: scale, restart policy, node eviction.
Only further slots stop being replaced.

**Fix.**
**Push a corrected spec.**
Any `satl service update` clears the paused status and starts the rollout fresh:

```sh
satl service update --image <working tag> <service>
```

Removing and recreating the service is not needed.
With `--update-failure-action rollback` the manager does this for you, swapping the spec back and ending at `rollback_completed`; a rollback that itself fails pauses rather than rolling again, and the same corrected-spec push gets it moving.

!!! note "`PreviousSpec` is empty after an automatic rollback"

    That is deliberate, and it matches SwarmKit: the spec that just failed is not a target to return to.
    So `?rollback=previous` has nothing to go back to until the next update.
    The field's absence looks like data loss and is not.

??? note "Why a rollout takes longer here than in Docker"

    An update takes at least `Monitor` **per batch**.
    SwarmKit starts the next batch as soon as the previous task reaches `RUNNING` and watches for failures in the background; SatL makes the failure-observation window part of the batch.
    With the defaults (parallelism 1, monitor 5 s) a six-replica update therefore takes at least 30 s.

    That is what makes each batch health-gated: a task that fails inside its window is caught before the next slot is disturbed.
    Set `--update-monitor` to a small value to get SwarmKit's pace back.

## A crash-looping task stopped being replaced { #restart-budget-spent }

**Symptom.**
A slot's task is in a terminal state with `DESIRED STATE` still `Running`, and nothing replaces it.

**Check**

```sh
sudo grep -a 'task not restarted' /var/log/messages
```

```
task not restarted task_id=… slot=1 state=failed trigger="task terminated" \
  attempts=2 reason="max restart attempts reached"
```

**Reading.**
The restart budget is spent.
`RestartPolicy.MaxAttempts` counts replacements per replica **and per spec version**, and the count is derived from the store's task history on every pass rather than held in a leader's memory, so it survives a manager restart and a leadership change.
A task left terminal at desired `Running` is what "nothing will replace this" looks like.
It is not a stuck orchestrator.

**Fix.**
A service update, any new spec version, starts a fresh budget.
Fix the reason it was crashing first.

## A drained node came back and stayed empty { #no-rebalance }

**Symptom.**
A node was drained, its tasks moved, it was set back to `active`, and it now runs nothing except global services.

**Reading.**
Correct.
**SatL has no rebalancer.**
The tasks the drain moved stay where they were re-placed: a 6-replica service drained off one of three nodes stays 3/3 on the survivors.
Moving a healthy task costs an outage for cosmetic balance, so it is not done.

A **global** service is the exception in the other direction: its task's node is
its identity, so a returning node gets a **new** global task on its own, with no
operator action.

**Fix.**
Anything that replaces the service's tasks spreads it again: scaling up and back down, or any `satl service update`.

??? note "What a drain does and does not wait for"

    Eviction from a draining node is the one case where SatL ignores the service's `RestartPolicy.Delay`: an operator emptying a node is waiting on it, so replacements are created immediately.
    Measured: a 6-replica service with a 30 s restart delay is fully re-placed **1–2 s** after the drain.

    Every other eviction pays the delay in full.
    In the log, a drain's evictions read `trigger="node is draining"` with `delay_ms=0`; a `Down` node's read `trigger="node is down"` with the service's own delay; a label change reads `trigger="node no longer satisfies the placement constraints"` with the delay.

    And a global service's task on a draining node is **stopped and not replaced** (`stopping a global task … reason="node is no longer eligible for this global service"`); there is no other node for it to run on.
    The service simply runs on one node fewer.

## Editing a node label moved running containers { #label-moves-tasks }

**Symptom.**
`satl node update --label-rm zone <node>` and, a restart delay later, containers are somewhere else.

**Reading.**
Placement constraints are **enforced continuously**: a task whose node stops matching is shut down and replaced on a node that does.
Editing a label is a placement change, and it costs the service's restart delay.

Two caveats worth knowing before you edit one:

- only an `active` node is judged.
  A `pause`d node keeps its tasks whatever its labels say, and a draining one is already losing them;
- **resource reservations are not re-checked**, only constraints and platform.
  A node whose capacity is edited downwards keeps the tasks it is already running.

**Fix.**
Put the node in `--availability pause` while you inspect or relabel it, if you would rather nothing moved.
