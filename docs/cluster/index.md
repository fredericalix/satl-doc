# Clustering

A SatL node self-initialises a single-node cluster the first time `satld` starts.
Not a standalone engine that can later be converted: a cluster, with a Raft store, a scheduler, a certificate authority and a node object, of which it is the only member.
Everything on this page follows from that one fact.

It means the second machine is a **join**, not a migration.
Nothing you configured on the first node has to be undone, no state is converted, and the vocabulary does not change; the service you created on one node is the same kind of object on three.
It also means `satl swarm init` is mostly a no-op: by the time you can run it the node is already a cluster, so it reports the node id and is **idempotent**.
Running it twice is not an error, and it is not how a cluster is created.

!!! info "`satl cluster` is the same verb"

    `satl cluster` is an accepted alias for `satl swarm`.
    The Docker verb is kept for compatibility; the alias reads better, and this site uses whichever fits the sentence.

## The CLI is local, always

`satl` speaks to a unix socket and only to a unix socket, `unix:///var/run/satl.sock` by default, `--host` or `DOCKER_HOST` to move it.
There is **no TCP client transport**, so there is no way to drive a remote cluster from your laptop.

Every command on this page is therefore run *on a node*, over ssh, and "on a manager" means exactly that.
The internal port 2377 is not a client port: it carries the node-to-node protocol and requires a node certificate no client has.

## Managers and workers

A **manager** holds the replicated store, participates in Raft, and may lead.
The leader additionally runs the loops that decide things: the scheduler, the replicated, global and jobs orchestrators, the allocator, the restart supervisor, the rolling updater, the task reaper, and the keyring rotation for encrypted networks.
Followers hold the same state and serve reads from it, forwarding writes to the leader.

A **worker** holds no replicated store at all.
That is the whole difference, and every worker-side surprise follows from it.

--8<-- "ops-manager-only.md"

Which means the list of things a worker cannot answer is longer than a Docker user expects.
It includes all of `satl network`, because a SatL network is a store object even when its driver is `bridge`.
It includes container lifecycle mutations too, because every container is a task of a service and creating one is a store write.
The full list, with what still works, is under [`This node is not a swarm manager.`](../trouble/cluster.md#not-a-swarm-manager).

Reads on a follower come from that follower's own applied state, which can lag the leader by a round trip.
Writes are forwarded; when there is no leader to forward to they are **refused**, not queued; see [`this cluster has no raft leader right now`](../trouble/cluster.md#no-raft-leader).

## Join tokens

A cluster has two tokens, one per role, and **the token you use decides the role the node joins with**.
There is no `--role` on join.

```sh
satl swarm join-token worker            # print the worker token, with a ready-to-paste join command
satl swarm join-token manager
satl swarm join-token -q worker         # the token alone, for a script
satl swarm join-token --rotate worker   # invalidate the old one
```

The format is `SATL-1-<digest>-<secret>`, and both halves earn their place.
The `secret` is 16 bytes of CSPRNG, compared in constant time.
The `digest` is a SHA-256 over the **whole** root CA bundle, and that is what makes the first contact safe.
A joiner downloads the trust bundle from a manager it cannot yet authenticate, hashes it, and refuses to go on unless the hash matches the token it was given.
Hashing the whole bundle rather than one certificate is deliberate; it catches a man in the middle *appending* a root of its own, which pinning a single certificate would not.

Two consequences to plan around:

- **A root CA rotation voids every older token.**
  Because the digest pins the whole bundle and the bundle changes shape during a rotation (old → old + new → new), tokens are regenerated **twice** per rotation: when it starts and when it completes.
  Docker regenerates only at completion.
  A token read just before [`satl ca rotate`](../reference/cli/ca.md#satl-ca-rotate) is void the moment the rotation begins.
- **Tooling that expects Docker's `SWMTKN` will not recognise these.**
  The prefix is `SATL`, on purpose.

!!! warning "A join token is a credential, and argv is public"

    Anyone holding the manager token can add a manager to your cluster.
    A token passed as a command-line argument appears in shell history and in `ps` output for as long as the command runs; SatL's own cluster harness feeds it on stdin for exactly that reason.

    Rotate with `satl swarm join-token --rotate <role>` if one leaks.
    Existing nodes are unaffected; a token authorises joining, not staying.

The failure modes are recognisable and separable: a token that never reached the network at all is a [malformed token](../trouble/tls.md#malformed-token), and one that reached a manager and was rejected on the digest is [`root CA bundle does not match the join token`](../trouble/tls.md#token-digest).

## Adding a node

On a manager, read the token for the role you want.
On the joining node:

```sh
satl swarm join --token <token> <manager-address>:2377
```

One manager address, and any manager will do; the joiner is redirected to the leader for the parts that need it.

What happens next is worth knowing, because it determines what a failed join costs you.
The joining node has no certificate, so it cannot use the mTLS port; it makes first contact on **2378**, the [bootstrap listener](../reference/ports.md#the-bootstrap-port), which is the one place in SatL that accepts a connection with no client certificate.
It fetches the trust bundle, checks the token's digest against it, and from that point every call runs over a connection pinned to the bundle it just verified.
Then it sends a certificate signing request, the cluster's CA issues its identity (`CN` = node id, `OU` = role, `O` = cluster id), and it verifies the result against both the pinned bundle and its own key before writing anything to disk.

!!! success "A failed join leaves the node's state alone"

    The certificate exchange runs **first**, and the node's existing cluster state is discarded only after it succeeds.
    So a bad token, an unreachable manager, or a digest mismatch costs you nothing: the node is exactly as it was.

    Past that point there is no half-way state either.
    If the rest of the join fails, the node re-initialises itself as a cluster of one rather than sitting inert.

A node that holds state a join would destroy is **refused** rather than silently emptied; a manager whose store holds services, tasks, secrets or other nodes, or a worker still running tasks of its current cluster.
A self-initialised node that has never been used holds nothing but itself and joins fine; the refusal and the ways out are under [a join is refused because the node already has state](../trouble/tls.md#join-refused-state).

### What the leader does with a join

Two steps that are easy to skip when reimplementing this, and both are load-bearing.

The leader **health-checks the joining node back** over mTLS before admitting it.
A member the leader cannot reach would otherwise count towards quorum while being unable to vote, which is how a three-manager cluster silently becomes unable to tolerate any failure.

The node is then admitted as a **learner** and promoted to voter once it is actually replicating.
The promotion is a background step, and it can fail to complete: the node reads `Ready` in `STATUS` and `Unknown` in `MANAGER STATUS`, and it **does not count towards quorum**.
Check that column after adding a manager, and rejoin the node if it stayed a learner.

## The ports between nodes

| Port | What it carries |
| --- | --- |
| **2377/tcp** | everything internal, over mutual TLS: Raft, the control API, the dispatcher, certificate renewals, health |
| **2378/tcp** | the CA bootstrap only, with **no client certificate**; a first-time joiner has none to present |
| **4789/udp** | the VXLAN data plane for unencrypted overlay networks |
| **4790–4999/udp** | one port per **encrypted** overlay network |
| **ESP** (IP protocol 50) | the encrypted overlay data plane itself |

2378 is derived, not configured: it is `listen_addr`'s port plus one.
Details, and a worked firewall policy, are in [Ports and firewall](../reference/ports.md).

The addresses a node listens on and advertises are set in [`satld.toml`](../config/satld-toml.md#cluster-addresses) and applied at startup.
`satl swarm init --advertise-addr` on a node that is already initialised is an error that says so and points back at the file; the node is already a cluster, so there is nothing to initialise and no address to choose.

## Promotion and demotion

```sh
satl node promote <node>                     # worker → manager
satl node demote  <node>                     # manager → worker
satl node update --role manager <node>       # the same thing, spelled the other way
```

Both apply **live**: the same daemon pid, running containers undisturbed.
That is not a convenience feature, it is a consequence of where the role is stored.
A node's role *is* its certificate's `OU`, so changing the role means re-issuing the certificate, and certificate renewal already swaps into the live TLS configuration without a restart, because listeners resolve their certificate per handshake.

Demotion is ordered deliberately: the node leaves Raft consensus **first**, and only then does its recorded role change.
The reverse order would let a renewal hand a worker certificate to a node that is still a voting member.

Because promotion applies live, it is also a usable emergency move: promoting a third manager *before* taking one down keeps quorum intact through the maintenance.

## Removing a node

```sh
satl node rm <node>
satl node rm --force <node>
```

A removal that would leave the cluster without a reachable majority is **refused**; the check counts the members that would still be reachable afterwards, using the transport's own liveness view rather than the store's opinion.

Removal is permanent in a specific way worth understanding before you use it as a maintenance step: a removed node's Raft identity is blacklisted and can never be re-admitted, and its certificate is blacklisted until it expires.
The node comes back only as a **new node id**, by rejoining with a fresh token, and anything that referred to the old id (a `node.id` constraint, a dashboard) has to be repointed.
That is also why `satl node rm --force` is a required step when replacing a manager that lost its state, rather than an optional tidy-up: the old member is still in the membership until you remove it.
The measured procedure is in [Backup and restore](backup-restore.md).

## How many managers to run

**Three, and a backup of two of them.**

The arithmetic is ordinary quorum arithmetic and it is unforgiving at small numbers.
Managers alone form quorum; adding workers never helps.
Three tolerate one loss, so a manager can be destroyed and rebuilt with no downtime and no backup.
One tolerates none, and its Raft directory is the only copy of everything the cluster knows.

!!! danger "Two managers are the worst of both"

    Quorum is 2 of 2, so losing either one stops every write **and** leaves the survivor in a state that cannot be repaired from inside the cluster: it cannot admit a replacement, and `--force-new-cluster` does not exist here.

    Run one manager and back it up, or run three and back up two.
    Never two.

The full picture (what has to be in a backup, why a rejoin usually beats a restore, and the measured numbers for each recovery) is [Backup and restore](backup-restore.md).
Read it before you deploy anything you care about, in particular [when quorum is gone](backup-restore.md#when-quorum-is-gone), which is the one situation with no recovery from inside the cluster.

## Reading the cluster's state

```sh
satl node ls
satl node inspect <node>
```

One column on `satl node ls` cannot be trusted, and it is the one people reach for during an incident.

!!! danger "`MANAGER STATUS` is written when the cluster forms and never refreshed"

    After a leadership change every node goes on calling the old leader `Leader`, permanently, including after that node rejoins as a follower.
    No API surface reports the live Raft leader either.

    `STATUS` (`Ready` / `Down`) **is** maintained and can be trusted.
    To establish that a leader exists, do a write and see it commit; to find out which node it is, read the logs.
    The procedure is [`satl node ls` names a dead node `Leader`](../trouble/cluster.md#stale-manager-status).

A node that stops answering its heartbeat is marked `Down` after roughly 15 seconds and its tasks are rescheduled, but **its containers were never stopped**, because they are jails and the daemon going away does not stop them.
That asymmetry is why a service can legitimately read more running replicas than it wants for a while: [a node reads `Down`](../trouble/cluster.md#node-down) and [`satl service ls` says `8/6`](../trouble/cluster.md#replica-count).

## Deciding where tasks run

```sh
satl node update --availability drain <node>     # empty it
satl node update --availability pause <node>     # no new tasks, leave the running ones
satl node update --availability active <node>    # schedulable again
satl node update --label-add zone=a <node>
```

`drain` evicts and reschedules; an eviction caused by a drain skips the service's restart delay, because an operator emptying a node is waiting on it.
`pause` is the one to use when you want to inspect or relabel a node without anything moving.

Two behaviours that surprise people, both correct:

- **Node labels are enforced continuously.**
  Editing a label is a placement change, so a task whose node stops matching its constraints is stopped and replaced on one that does; see [editing a node label moved running containers](../trouble/cluster.md#label-moves-tasks).
- **There is no rebalancer.**
  A drained node brought back `active` stays empty until something replaces the service's tasks.
  Moving a healthy task for cosmetic balance would cost an outage, so it is not done; [a drained node came back and stayed empty](../trouble/cluster.md#no-rebalance).

## The overlay

Cluster-wide networking is one command:

```sh
satl network create --driver overlay backend
satl network create --driver overlay --opt encrypted backend
```

Each overlay gets its own VXLAN network identifier and a subnet allocated cluster-wide in Raft, and the forwarding table is distributed from the store rather than learned from traffic.
Its **gateway address is per node**, not cluster-wide, because every participating node's bridge sits on one L2 segment and a single shared address would be a duplicate there, so `satl network inspect` reports this node's gateway, and a node running no task on the network reports none.

Service discovery is DNS round-robin against the running tasks, with no virtual IP: FreeBSD has no IPVS, and a VIP mode is refused rather than quietly downgraded.
`--opt encrypted` wraps the network's VXLAN datagrams in IPsec ESP with keys the cluster generates and rotates itself, chosen per network at creation, costing 34 bytes of MTU on top of VXLAN's 50.

All of it (addressing, container DNS, why VXLAN, what encryption protects and what it does not) is in [Networks](../use/networks.md), and the encryption section is [there](../use/networks.md#encrypted).

## Certificates look after themselves

Every node's certificate is renewed automatically part-way through its validity and swapped into the live TLS configuration without a restart, and `satl ca rotate` replaces the cluster root on a live cluster with no downtime.
Nothing here needs an operator until something goes wrong, and when it does the symptoms are all the same shape: a connection that never establishes.

```sh
satl ca                 # the root certificate(s) this cluster trusts
satl ca rotate
```

Two failure modes are worth knowing exist before you meet them.
A node that was **offline across a root rotation** chains to a root nobody trusts any more and must rejoin ([`refused an internal TLS connection`](../trouble/tls.md#refused-tls)).
An **expired** certificate breaks nothing until the first reconnect, at which point everything fails at once and looks like a network event ([everything fails at once](../trouble/tls.md#expired-certs)).
A rotation also waits for every node the store still lists, so a node that is down [holds it open](../trouble/tls.md#rotation-stuck).

## Locking the managers

The Raft log and its snapshots are sealed on disk with a per-node key.
By default that key sits next to them, which protects against a stolen disk and not against a stolen machine.
Autolock seals it under a cluster-wide unlock key instead:

```sh
satl swarm update --autolock=true
satl swarm unlock-key                # print it — store it somewhere that is not the node
satl swarm unlock-key --rotate
satl swarm unlock                    # after a restart
```

A locked manager is genuinely locked: it answers `GET /_ping` and the unlock call and nothing else, so `satl node ls` on it fails until you unlock it.
**A worker is never locked**: it has no Raft log, so there is nothing on it to seal.
The on-disk side of this is in [Node state on disk](../config/state.md#autolock).

!!! danger "Store the unlock key off the node"

    A locked cluster whose unlock key is only on the locked managers does not start.
    The key is printed once by `satl swarm unlock-key` and it is not recoverable from the sealed state.

## Where to go next

| You want to | Read |
| --- | --- |
| decide a topology, and back it up | [Backup and restore](backup-restore.md) |
| understand the overlay properly | [Networks](../use/networks.md) |
| publish a port across the cluster | [Publishing ports](../use/publishing-ports.md) |
| roll out a new version safely | [Rolling updates](../use/rolling-updates.md) |
| diagnose a cluster that is misbehaving | [The cluster](../trouble/cluster.md) and [TLS, joins and certificates](../trouble/tls.md) |
| look up a flag | [`satl swarm`](../reference/cli/swarm.md#satl-swarm), [`satl node`](../reference/cli/node.md#satl-node), [`satl ca`](../reference/cli/ca.md#satl-ca) |
| open the firewall | [Ports and firewall](../reference/ports.md) |

Everything on this page was exercised on a three-node cluster of FreeBSD VMs (4 vCPU, 8 GiB, ZFS) on 15.1-RELEASE and on CURRENT.
Where a number is quoted it was measured there, and where a recovery is described it was performed there.
