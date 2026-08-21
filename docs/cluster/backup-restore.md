# Backup and restore

Everything the cluster knows (services, tasks, networks, nodes, secrets, configs, allocations, and the root CA itself) lives in one directory on each manager: `<state_dir>/raft`.
Nothing else in the state directory is cluster state; the rest is node-local and rebuildable.

So a backup of a SatL cluster is a copy of that directory, from a manager.
What follows is the procedure, and the numbers that decide when you actually need it.

## Read this before writing a cron job

!!! success "While quorum holds, rejoin beats restore"

    A manager that lost its state does not need a backup.
    Remove it from the membership and join it again, measured at **6 seconds** end to end, with the cluster committing writes throughout.

    A restore is not slower by much, but it is only *available* if you took a copy.
    The rejoin needs nothing.

| Recovery | Needs a backup | Measured, end to end |
| --- | --- | --- |
| a manager's raft directory restored from a copy of *that* manager | yes | ~2 s of downtime, then 3–4 s to catch up (5 runs) |
| the same manager wiped and re-joined | **no** | **6 s** |
| a one-manager cluster restored from a copy | yes | full recovery: services, secrets, the running container |
| a one-manager cluster with no copy | no copy to need | **nothing comes back** |

The arithmetic is the ordinary quorum arithmetic.
Three managers tolerate one loss, so a manager can be destroyed and rebuilt with no downtime and no backup.
One manager tolerates none, and its raft directory is the only copy of everything in the cluster.

!!! danger "The policy is three managers **and** a backup of two of them"

    A rejoin covers one manager failing.
    It covers nothing the day the *majority* goes: a cluster that has lost quorum cannot admit a replacement, cannot be forced into a smaller membership, and cannot even be stopped cleanly.
    There is no recovery from inside it.
    Only a backup gets you out, and one manager's backup is not a majority; you need two of the three.

    **Two managers are the worst of both.**
    Quorum is 2, so losing either one stops every write *and* leaves the survivor in that unrecoverable state.
    Run one and back it up, or run three and back up two.

## What has to be in the copy

Everything in `<state_dir>/raft`, and the `dek` is not optional:

```console
$ ls -l /var/db/satl/raft
-rw-------  1 root wheel       32  dek         # the key. 0600, never in a log, never shared
-rw-r--r--  1 root wheel 18878464  log.redb    # the raft log, sealed with that key
-rw-r--r--  1 root wheel       26  node-id     # this node's cluster identity
-rw-r--r--  1 root wheel       20  raft-id     # this node's raft member id
```

- **`dek`** is generated per node from OS randomness, and a record sealed under one manager's key does not open under another's.
  **Another manager's backup is not a substitute**: the copy is only ever useful to the node it came from.
- **`node-id` and `raft-id`** are why a restored node comes back *as itself* rather than as a new member.
  They are plain files, they travel in the copy, and the daemon reads them instead of minting new ones.
- **`snapshot`** appears once the log has passed roughly 10 000 entries, sealed with the same key.
  Copy it if it is there; after a compaction it is where most of the state lives.
- **`log.redb` is sparse and only grows.**
  It was 19 MB on a manager holding about 230 small objects, and 1.1 GB after a synthetic burst of 10 000 writes of 64 KiB objects.
  A compaction does not shrink the file.
  Size the backup target for the file, not for the state.

!!! note "`certs/` is not part of this copy, and does not need to be"

    The raft state contains the cluster's CA, so a node whose raft directory is intact **re-issues its own certificate**.
    Verified by deleting `<state_dir>/certs` outright and starting the daemon, same node id, service still running, and three lines in the log:

    ```
    INFO satld::cluster: no node certificate found; initializing this node's identity
    INFO satl_cluster::node: raft state found, resuming existing cluster raft_id=6418088851891314064
    INFO satld::cluster: re-issued this node's certificate from the cluster CA already in the store
    ```

    The two directories are not interchangeable in the other direction:
    certificates *without* raft state are the refusal described in
    [a single-manager cluster](#the-single-manager-cluster), below.

## Taking the copy

`<state_dir>/raft` is its own ZFS dataset.
That is what makes this easy.

### Snapshot the dataset: the recommended way

A ZFS snapshot is atomic and crash-consistent, which is precisely the image the
raft log's storage engine is built to recover from, recovery from a `kill -9` is
already part of SatL's own acceptance tests.

```sh
zfs snapshot zroot/satl/raft@backup
tar -C /var/db/satl/raft/.zfs/snapshot/backup -cf /var/backups/satl-raft.tar .
zfs destroy zroot/satl/raft@backup
```

The snapshot directory is readable whether or not `snapdir` is visible, and the
files in it keep their modes, `tar` preserves the `dek`'s `0600`.

### Stop the daemon, copy, start it: unambiguous

On a three-manager cluster this costs nothing: the other two keep committing, and
the stop took 0.05 s on a healthy manager.

```sh
service satld stop
tar -C /var/db/satl/raft -cf /var/backups/satl-raft-$(date +%F).tar .
service satld start
```

!!! warning "Take the copy after the daemon has *actually* gone"

    `pgrep satld`, not "`service satld stop` returned".
    On a manager that has lost its quorum the stop can hang for a very long time (see [below](#when-quorum-is-gone)), and a copy taken in that window is a copy of a running daemon's files.

### `cp -Rp` of a live raft directory: it worked, and still avoid it

Three copies taken from a running manager while the cluster committed about 35 store writes a second were each restored onto that node, and all three came back and caught up.
That is 3 for 3, and it is **not** a guarantee.

!!! danger "\"It started\" is not evidence that a copy was sound"

    `cp` reads a file that is being written, so the result is a smear across the
    copy window rather than a point in time, and nothing in the storage engine's
    design promises a smeared file is consistent.

    Nothing here detected a bad copy either: a **deliberately torn** file (one half read six seconds after the other) opened and ran anyway.
    So a restore that starts tells you nothing about whether the copy was whole.

    A snapshot removes the question for free.
    There is no reason to rely on the luck.

### How stale a copy may be

**On a multi-manager cluster, stale is fine.**
The copy only has to give raft a starting point; the leader replays the rest.
Copies a minute old, and copies taken before hundreds of writes, all converged 3–4 s after the daemon came up.

**On a single-manager cluster the opposite holds.**
Everything committed after the copy is gone, so the backup interval *is* the amount of work you are choosing to lose.

## Restoring onto the same node

The daemon must be stopped first; two raft instances must never share one raft
directory, and the directory is a dataset mountpoint, so **empty it rather than
removing it**:

```sh
service satld stop
rm -rf /var/db/satl/raft/*                      # empty the dataset, keep the dataset
tar -C /var/db/satl/raft -xf /var/backups/satl-raft.tar
service satld start
```

Nothing has to be told to the cluster and nothing has to be passed to the daemon: no `swarm init`, no `--advertise-addr` (which is refused anyway, first boot *is* the init).
What the log says is how you know it took:

```
INFO satl_cluster::node: raft storage opened node_id=23hfzohfbk3d80bbf5z8a6hkg
     raft_id=2173359823421821951 raft_dir=/var/db/satl/raft
INFO satl_cluster::node: raft state found, resuming existing cluster raft_id=2173359823421821951
INFO satld::cluster: cluster state ready node_id=23hfzohfbk3d80bbf5z8a6hkg … joined=false
```

- **`raft state found, resuming existing cluster` is the line to look for.**
  Its opposite, `pristine node, initializing single-node cluster`, means the daemon found nothing to resume, on a node that was in a cluster, that is a restore which did not happen.
- `node_id` and `raft_id` must be the values the node had before.
  They came out of the copy; if they changed, the copy was not this node's.
- Over five restore-and-restart cycles the node caught up **3–4 s after start**,
  every time, including entries written while it was down.
- **The containers on that node keep running throughout.**
  They are jails; the daemon stopping does not stop them, and the startup reconciliation re-adopts them.
  A restore is not an outage for the workload on that node.

### Restoring without the `dek`

The one mistake this page exists to prevent.

!!! failure "A raft directory whose `dek` is missing is refused, not re-keyed"

    ```
    Error: cluster bring-up failed
    Caused by: the raft state in /var/db/satl/raft is sealed but its key file is
      missing: /var/db/satl/raft/dek. log.redb cannot be read without it, and satld
      will not create a new key over sealed data. Restore the key file from the same
      backup as the rest of /var/db/satl/raft (it is per-node and never shared:
      another manager's key does not open this one's state). If this node's cluster
      state is unrecoverable, empty /var/db/satl/raft instead and re-join the node
    ```

    Put the file back and the same start succeeds with the full state.
    The refusal is the feature: a fresh key written over a sealed log would make the state **permanently unreadable**, and the key is usually still in the backup.

    Two related refusals, same reason: a `dek` that is group- or world-readable is
    refused with `chmod 600` in the message; that is what a careless `umask`
    during a restore produces, and a `dek` of the wrong length is refused as
    corrupt rather than used.

## Losing a manager entirely: rejoin, do not restore

On a cluster with other managers this is the ordinary path and it needs no backup at all.
Three steps, **6 s** end to end:

```sh
# on the node that lost its state
satl swarm leave --force

# on any surviving manager: the old member is still in the membership and in
# `satl node ls`, and it has to go before its replacement arrives
satl node rm --force <old node id>
satl swarm join-token -q manager

# back on the node
satl swarm join --token <token> <any manager>:2377
```

What to expect, all of it observed:

- **the node comes back under a new node id.**
  Identity is issued by the cluster it joins, so its old id is gone for good, which is why `satl node rm --force` is part of the procedure and not an optional tidy-up.
  Anything that referred to the old id (a `node.labels` constraint pinned to it, a dashboard) has to be repointed.
- **its containers are not its own any more.**
  Whatever it was running was rescheduled while it was `Down`, and its reconciliation pass reaps the leftovers when it comes back.
- **`satl swarm leave --force` is not "make this node idle".**
  The node immediately forms a fresh single-node cluster of its own, and `satl node ls` on it lists one node, itself, as Leader.
  That is expected: it is a cluster of one until the join lands.
- **if the daemon cannot start**, `satl swarm leave --force` is not available.
  Discard the identity by hand, which is what the refusal tells you to do: `rm -rf <state_dir>/certs`, empty `<state_dir>/raft`, start `satld` (it forms its own single-node cluster), then `satl swarm join`.
- **check `MANAGER STATUS` afterwards.**
  A join whose learner-to-voter step does not complete leaves the node a learner: `satl node ls` shows `Unknown` in that column and the leader logged `learner never acknowledged replication; it stays a learner and does not count towards quorum`.
  It is not a voting manager in that state, whatever the `Ready` in the `STATUS` column suggests.
  Rejoin it.

A restore is the right answer when the cluster still has quorum and you would rather not lose the node's identity.
It is the *only* answer once quorum is gone.

## When quorum is gone { #when-quorum-is-gone }

A cluster commits writes only while a majority of its managers are up.
Measured on a three-manager cluster by destroying two of them and restarting the third:

!!! danger "With one of three left, nothing can be fixed from inside the cluster"

    - **Writes hang.
      They do not fail.**
      `satl secret create` sat there until a 20 s `timeout` killed it.
      A raft proposal has no timeout by design (a timeout cannot retract an appended entry), so a write aimed at a quorum that will never form waits for ever, and nothing tells you why.
    - **Reads keep working and `satl node ls` lies.**
      It listed all three nodes `Ready`, with the survivor as `Leader`: the store frozen at its last applied state and a leftover leader from the term before the restart.
      In this state that column is not evidence of anything.
    - **A replacement manager cannot join.**
      The join needs a certificate, issuing one is a store write, and the store cannot commit, `NodeCA IssueNodeCertificate … "Timeout expired"`.
    - **`satl swarm init --force-new-cluster` answers `501`.**
      There is no way to shrink the membership to the survivor, which is exactly what Docker's flag exists for.
    - **`service satld stop` hangs**: 21 minutes, in the run that measured it, before it was killed.
      Use `pkill -9 satld`: the raft directory is crash-safe by construction, and this is the one state where a graceful stop is not available.

**Restoring a second manager brings it back, and that is the whole recovery.**
One node's raft directory was restored from its own backup (the raft directory only, no certificates), and its daemon started:

```
INFO satld::cluster: re-issued this node's certificate from the cluster CA already in the store
INFO satl_cluster::node: raft state found, resuming existing cluster raft_id=1971981655582681656
INFO satld::cluster: cluster state ready node_id=2gsc8z0qa8db2sk8c7cigvaqv
```

Two of three voters is a majority, so the cluster committed immediately, and the write that had been hanging *landed*: the retry answered `a secret named q2_after already exists`, which was the pending proposal from before the restore going through.
`satl node ls` then showed the third node `Down`, correctly, and the service that had lost a replica was being re-placed.

### The arithmetic that decides your backup policy

| Managers | Lost | Recovery | Backup needed |
| --- | --- | --- | --- |
| 3 | 1 | rejoin the node (6 s), or restore it, either works | none |
| 3 | 2 | restore **two** of the three raft directories: one is not a majority | 2 of 3 |
| 3 | 3 | restore two, then rejoin the third | 2 of 3 |
| 1 | 1 | restore its raft directory | that one |
| any | quorum, with no backups | **none. The cluster cannot be recovered** | none would help |

Every row was run on the test cluster except the third, which follows from the row above it by the same arithmetic.
That last row is the sharp edge of this whole page, and it is why the advice is the boring one: **if the cluster matters, run three managers and copy the raft directory of at least two of them.**

## The single-manager cluster { #the-single-manager-cluster }

A one-manager cluster cannot re-sync from anywhere.
All three cases below were run.

**With a backup: full recovery.**
A single-node cluster holding a secret, a service, a running container and its own root CA had its raft directory destroyed and restored from a stopped-daemon tar.
Everything came back: the secret, the service at 1/1, the container still `Up` (it never stopped), the same node id.

**With no backup: nothing comes back, and the daemon says so before it does any damage.**
With the certificates still on disk and the raft directory empty, `satld` refuses to start:

```
Error: cluster bring-up failed
Caused by: this node holds a manager certificate for cluster 2e9za8a7stl3nuzf04v2zc3j8
  but its raft state directory /var/db/satl/raft is empty, so there is nothing to
  resume and satld will not form a new cluster here (that would silently replace
  the cluster this certificate belongs to with an empty one). Restore
  /var/db/satl/raft from a backup of THIS node, the 'dek' key file included …
```

!!! success "That refusal is the point"

    A manager certificate is only ever issued to a node that already has raft
    state, so a certificate over an empty raft directory is **never a first
    boot**; it is state that was lost, or a restore that has not been done yet.

    Starting anyway would mint a second cluster under the same certificate: empty, with a new cluster id and no root CA, **looking perfectly healthy** while every service, secret and network you had was gone.
    The daemon stops instead, and names both recoveries.

**And if you remove the certificates too**, that is exactly what you get, measured: a new node id, an empty store, no secrets, no services, and the startup reconciliation destroying the container that belonged to the old cluster.
There is no way back from there and no half-way state; the old cluster's root CA and join tokens were in the raft state that is gone.

**There is no `ForceNewCluster`**, and it is a decision rather than an omission.
A manager that *has* its raft state does not need forcing; restarting `satld` resumes it.
One that does not have it has nothing to force from.

So on a one-manager deployment, schedule the copy.
A stopped-daemon `tar`, or a `zfs snapshot` piped off the node with `zfs send`, in cron, with the `dek` in it.

## What a raft backup does not cover

Only cluster state.
Images, layers, containers and volumes are **node-local**, the same asymmetry [`satl system prune` has](../use/reclaiming-space.md#it-is-node-local-for-everything-that-costs-disk), they are rebuilt by pulling and by rescheduling, and none of them is in a raft backup.

There is also **no cluster-wide backup command and no `satl` verb for any of this**.
Everything above is `zfs`, `tar` and two cluster commands, on purpose: a backup you run with the tools you already have is a backup you can audit.
