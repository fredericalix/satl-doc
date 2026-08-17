# How it works

This page is the mental model and the vocabulary.
Everything else on this site uses these words in exactly this sense.

## The words

**Node** — one machine running one `satld`.
Every node has a durable identity (a 25-character id) and an mTLS certificate issued by the cluster's own CA.
A node is either a manager or a worker, and the role *is* the certificate's organisational unit, which is why changing it means re-issuing a certificate.

**Manager** — a node that holds a replica of the cluster store and participates in Raft.
Managers elect a leader; the leader schedules.
A manager also runs tasks: it is not a dedicated control-plane machine unless you drain it.

**Worker** — a node that runs tasks and nothing else.
No Raft, no store, no listener of its own.
A worker's only durable state is its certificate, its local task database and the manager list it was last told about.
Cluster-scoped commands on a worker (`satl service ls`, `satl node ls`, `satl network ls`) answer Docker's own refusal with a 503; local reads (`satl ps`, `satl logs`, `satl exec`) work and show that node's own containers.

**Service** — the declaration.
An image, a command, an environment, networks, published ports, a replica count or `--mode global`, a restart policy and an update policy.
This is what you create and update; you never manipulate a container directly.

**Task** — one attempt at running one replica of a service, on one node, as one jail.
Immutable once created.
A task that dies is not restarted — it is *replaced* by a new task with a new id.

**Slot** — the replica's identity across task replacements.
A four-replica service has slots 1 to 4; slot 3 may be on its seventh task by Friday and it is still slot 3.
Task names read `<service>.<slot>.<task id>`.
A **global** service has no slots — its identity is the node, so its tasks read `<service>.<node id>.<task id>`.

**Desired state and current state** — the two halves of every reconciliation loop.
Desired state is what the store says should be true (this service wants four replicas; this task should reach `RUNNING`).
Current state is what the agents report (this task is `PREPARING`; this node has not checked in for 30 seconds).
Nothing in SatL is triggered by an event alone: the loops compare the two and act on the difference, so a message lost while a node was away is simply noticed on the next pass.

## One node

`satl` never touches the host directly.
It speaks the Docker REST API over a unix socket, and everything below the socket is `satld`.

```text
   satl / docker CLI
          |
          |  Docker Engine API v1.43
          v
   /var/run/satl.sock
  =============================================================== satld ===
   REST API
      |
      |  store writes (services, tasks, nodes, networks, secrets)
      v
   Raft store  --->  scheduler  --->  orchestrator loops
   (this node is a                    (replicas, restarts, rolling updates,
    cluster of one)                    global services, allocators)
      |
      |  assignments
      v
   dispatcher  <---- session ----  agent  ---->  executor
                                                    |
                            +-----------------------+------------------+
                            |                 |              |         |
                            v                 v              v         v
                       image store       ZFS layers      satl-net    ocijail
                      (OCI pulls)      (snapshot+clone)  (bridge,   (create,
                                                          epair,     start,
                                                          pf)        kill)
                                                                       |
                                                                       v
                                                                  jail (VNET)
  =========================================================================
```

Two things in that picture are less obvious than they look.

The **agent talks to the dispatcher even on a single node** — over a local unix socket at `<state_dir>/dispatcher.sock` rather than over the network, but it is the same session protocol a remote worker uses.
There is no shortcut path for the one-node case, which is why the one-node case and the cluster case behave identically.

And the **store is the only place cluster state lives**.
Nothing is kept in a side channel.
A worker holds ephemeral executor state only, rebuilt from dispatcher assignments after a restart.
This is what makes `kill -9 satld` survivable: the containers keep running, and the next start re-attaches them from what the store and the local task database agree on.

## Three nodes

```text
   node1 (manager, leader)     node2 (manager)          node3 (worker)
  +----------------------+    +--------------------+   +------------------+
  | raft store  <========|====|=> raft store       |   | (no store)       |
  | scheduler            |    |                    |   |                  |
  | orchestrator         |    |                    |   |                  |
  | dispatcher <---------|--+ | dispatcher         |   |                  |
  | NodeCA               |  | |                    |   |                  |
  |                      |  | |                    |   |                  |
  | agent ---------------|--+ | agent -------------|-+ | agent -----------|-+
  | executor -> jails    |    | executor -> jails  | | | executor->jails  | |
  +----------------------+    +--------------------+ | +------------------+ |
        ^      ^                                     |                      |
        |      +-------------------------------------+                      |
        +----------------------------------------------------------------- +
              sessions: workers dial managers, never the reverse

   control plane : 2377/tcp  mTLS  (raft, control, dispatcher, NodeCA, health)
   CA bootstrap  : 2378/tcp  plain (a joiner has no certificate yet)
   overlay data  : 4789/udp  VXLAN, unicast, static forwarding table
                   (a network created with --opt encrypted moves to a dedicated
                   port from 4790-4999 and crosses the wire as IPsec ESP)
```

Three properties of that picture are load-bearing:

- **Managers never dial workers.**
  Every session is opened and maintained by the worker's agent toward a manager, which is what makes SatL work through a firewall that only allows outbound connections from workers.
- **Every write goes through the leader.**
  A follower that receives a mutation forwards it once, with the leader's address in the response metadata.
  Reads are served from the local replica.
- **The second port exists for one reason.**
  The mTLS server on 2377 demands a client certificate on every connection, and a node joining for the first time does not have one. 2378 serves the unauthenticated bootstrap: the joiner fetches the root CA and submits a signing request, and pins what it receives against the digest baked into its join token.
  You only ever type 2377 — `satl swarm join host:2377` derives the other.

## The loop, once

Putting it together, here is what `satl service create --replicas 3 --publish 8080:80 web` does:

1. The CLI posts a service spec to the REST API on whichever node you ran it on.
   If that node is a follower, the write is forwarded to the leader.
2. The leader commits the Service object through Raft.
   The allocators claim a published port (cluster-wide, sticky) and, for an overlay network, a subnet, a VNI and per-task addresses.
3. The replicated orchestrator sees a service wanting three tasks and zero
   existing, and commits three Task objects in state `NEW`.
4. The scheduler filters candidate nodes (ready, enough resources, constraints satisfied, platform matching, no host-port conflict) and ranks the survivors by spread.
   Each task moves to `ASSIGNED` with a node id on it.
5. Each node's dispatcher session delivers the assignment.
   The agent accepts, pulls the image if needed, clones the layers, builds the OCI spec, creates the epair and the jail, and drives the task through `PREPARING`, `READY`, `STARTING`, `RUNNING` — reporting each step back over the session.
6. Meanwhile a periodic pass on each node re-derives the whole `satl/rdr` pf anchor from the tasks that are running *there*, and loads it if the text changed.
   That is how a published port arrives without anyone announcing it.

If step 5 fails, the task ends `FAILED`, the restart supervisor decides whether to replace it under the service's policy, and the scheduler places the replacement.
Nobody had to notice; the loops compared desired state to current state and the difference was the work.
