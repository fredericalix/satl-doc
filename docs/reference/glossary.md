# Glossary

The words this documentation uses precisely.
Most come from SwarmKit, which is also where their exact meaning comes from, where SatL uses a term differently, the entry says so.

## Nodes and roles

### Node

One host running `satld`.
A node has a 25-character cluster identity that survives restarts, a certificate issued by the cluster's own CA, and exactly one role at a time.

### Manager

A node that holds the replicated cluster state: it runs Raft, serves the internal listeners, and, when it is the leader, runs the orchestrator, the scheduler, the allocators and the dispatcher.
**A manager runs tasks too**; it is not a control-plane-only machine.

Managers alone form quorum.
Two managers plus a worker tolerate *no* manager failure.

### Worker

A node that runs tasks and nothing else: no Raft, no store, no internal listener of its own.
It maintains an outbound session to a manager and receives its assignments over it.
Cluster-scoped commands on a worker answer Docker's own refusal; run them on a manager.

Promotion and demotion apply **live**, without a daemon restart and without
disturbing running containers.

### Leader

The manager that currently holds Raft leadership.
Every mutation of cluster state is committed through it; a follower that receives one forwards it.

!!! warning "`satl node ls` does not tell you who the leader is"

    Its `MANAGER STATUS` column is written when the cluster forms and never refreshed, so it can name a dead node `Leader` indefinitely.
    Read leadership from the daemon log instead; see [Troubleshooting](../trouble/cluster.md#stale-manager-status).

## Workloads

### Service

The declarative unit: an image, a command, an environment, networks, mounts, resources, a restart policy, an update policy, and how many copies to run.
You describe a service; the cluster makes reality match it.

### Task

One container, and the atom of scheduling.
A task belongs to exactly one service, is placed on exactly one node, and is **one-shot**: it is never restarted, only replaced by a new task with a new ID.
In the Docker API a "container" *is* a task, which is why `docker start` on a stopped container is refused.

Even `satl run` creates a service, an anonymous single-replica one, and the
container you get is its task.

### Slot

The replica index within a replicated service: `web.1`, `web.2`, … A slot persists across replacements, so "slot 3 has failed four times" is a meaningful sentence where "task X has failed four times" is not (a task fails at most once).
Restart budgets are counted per slot.

A **global** service has no slots: its tasks carry slot 0 and are named after
the node instead, `<service>.<node id>.<task id>`, because the node *is* the
replica identity.

### Replica

One running copy of a replicated service.
`--replicas 6` asks for six, spread by the scheduler.

### Global service

A service that runs **one task per eligible node** instead of a fixed count (`--mode global`).
It has no replica count, so `--replicas` is refused on both verbs and `satl service scale` answers that scale can only be used with replicated mode.
Its `REPLICAS` column reads `running/wanted`, where "wanted" is what the cluster currently wants, so a global service on three nodes with one drained honestly reads `2/2`, not `2/3`.

A global task whose node becomes ineligible is stopped and **not** replaced elsewhere; the service simply runs on one node fewer.
Put the node back to `active` and it gets a new task there on its own.

## State

### Desired state and current state

Two independent fields on every task.

**Desired state** is what a manager has decided should happen to this task: `Ready`, `Running`, `Shutdown`, `Remove`.
It is written by the control plane and travels outward to the node.

**Current state** is what the node last observed: the task's position in the state machine: `NEW`, `PENDING`, `ASSIGNED`, `ACCEPTED`, `PREPARING`, `READY`, `STARTING`, `RUNNING`, and then `COMPLETE`, `FAILED` or `SHUTDOWN` (with `REJECTED` and `ORPHANED` off to the side).
It travels inward from the node.

The two are shown side by side in `satl service ps`, and they legitimately
disagree; that disagreement is what reconciliation *is*.

### Live task { #live-task }

A task whose **desired state is `Running` and whose current state is also `Running`**.
Both halves are required, and this is the definition worth internalising because it explains a number that otherwise looks like a bug.

A task on a node that stopped answering keeps its last reported `Running` (nothing can report otherwise, and the node-down-to-orphaned timer is 24 h), while the manager has already moved its *desired* state on and scheduled a replacement.
Counting observed `Running` alone therefore says "8 tasks running" for a six-replica service with one node down.

**`satl service ls` shows exactly that as `8/6` while a node is down, and it is correct to.**
Six of those are live; two are tasks the cluster no longer wants and cannot yet confirm are gone.

### Availability

What a node is willing to do, set with
`satl node update --availability <state>`:

| | |
| --- | --- |
| `active` | the normal state: runs tasks, takes new ones |
| `pause` | keeps what it runs, takes no new tasks. Nothing is moved off it; this is the state to put a node in while you inspect it |
| `drain` | gives up every task it runs, and takes none |

A drain does **not** pay the service's restart delay: an operator emptying a
node is waiting on it, so replacements are created immediately.

### Constraint

A placement expression matched against a node's labels and built-in attributes (`node.hostname`, `node.role`, `node.labels.<key>`, …), given with `--constraint`.
Constraints are enforced **continuously**: a task whose node stops matching is shut down and replaced on one that does, so editing a node label is a placement change that moves running containers.

Only an `active` node is judged, and resource reservations are not re-checked,
only constraints and platform.

## Networking

### VTEP

*VXLAN Tunnel End Point.*
The interface on a node that encapsulates and decapsulates overlay frames.
One per overlay network per participating node, created by SatL and named `satl-vx-<network>`.

An interface that is `UP` but not `RUNNING` is a VTEP the driver refused to
initialise, and `ifconfig` reports success for it regardless.

### VNI

*VXLAN Network Identifier.*
The 24-bit number that separates one overlay network from another on the wire.
SatL's allocator assigns one per overlay network and reports it as an extra `Vni` field in `network inspect`.
Two interfaces with the same VNI on one node's VXLAN socket is an error the kernel reports on `up`.

### FDB

*Forwarding database.*
The VXLAN interface's table of "this inner MAC lives behind that remote VTEP address".
SatL programs it **statically** from cluster state, learning is disabled, because a learned entry that ages out after twenty minutes is not something a reconciler can reason about.

The FDB is **per direction**: an entry missing on one node breaks the pair in
both directions, and the node reporting total loss is usually the correctly
configured one.

### Anchor

A named container for `pf(4)` rules.
SatL owns `satl/*` and never touches rules outside it: `satl/nat` holds the container egress translation, `satl/rdr` the published-port redirects.
An operator declares the anchors once in `/etc/pf.conf`; see [Ports and firewall](ports.md#pf).

## Security

### Join token

The credential that admits a node to the cluster, spelled `SATL-1-<digest>-<secret>`.
`<digest>` pins a hash of the cluster's **entire root CA trust bundle**, which is what makes the unauthenticated first contact safe: a joiner refuses a bundle that does not hash to what its token says.

Two tokens exist at any time, one per role, printed by `satl swarm join-token worker|manager`.
**Every token is void the moment a root CA rotation starts**, and again when it completes; the digest pins the bundle, and the bundle changes at both moments.

### DEK

*Data encryption key.*
The per-manager key at `<state_dir>/raft/dek`, mode `0600`, that encrypts the Raft log and its snapshots at rest.

Losing it makes that node's local Raft state unreadable.
On a multi-manager cluster the node can re-sync from its peers; a single-node cluster's state is gone.
Include it in any copy of `<state_dir>/raft`, and protect it exactly like a private key; in particular, never paste it into a bug report.

### Trust bundle

The set of root certificates the cluster currently accepts, normally one, and temporarily **two** during a root CA rotation, while every node is being re-issued under the new root.
`satl ca` prints it.
