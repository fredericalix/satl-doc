# Node state on disk

Everything a node knows lives under one ZFS dataset.
On a default install that is `zroot/satl`, mounted at `/var/db/satl`, and the two are configured separately — [`zfs_root`](satld-toml.md#storage-first-because-it-is-the-one-that-refuses-to-start) names the dataset, `state_dir` names the path — which is why `satld` warns at startup when they disagree.

Some of what is below is a dataset in its own right, and some is a plain directory on the root dataset.
The difference matters: a dataset is what SatL snapshots, clones and destroys.

## Datasets

```
zroot/satl                              /var/db/satl
├── raft                                cluster state (managers only)
├── images                              image blobs and metadata
├── layers/<chain-id>                   one dataset per applied layer chain
├── containers/<task-id>                one clone per container's writable layer
└── volumes/<volume-name>               one dataset per named volume
```

`zfs list -r zroot/satl` is therefore a genuine inventory of what a node holds:

```console
$ zfs list -r zroot/satl
NAME                                       USED  AVAIL  REFER  MOUNTPOINT
zroot/satl                                81.2M   683G   596K  /var/db/satl
zroot/satl/containers                     1020K   683G   128K  /var/db/satl/containers
zroot/satl/containers/2qw3gxb4uklpaow…     428K   683G  49.3M  /var/db/satl/containers/2qw3…
zroot/satl/images                         19.0M   683G  19.0M  /var/db/satl/images
zroot/satl/layers                         59.4M   683G   128K  /var/db/satl/layers
zroot/satl/layers/34884abbe92863fce93…    9.65M   683G  9.50M  /var/db/satl/layers/34884…
zroot/satl/raft                           1.11M   683G  1.11M  /var/db/satl/raft
zroot/satl/volumes                          96K   683G    96K  /var/db/satl/volumes
```

**`raft`** holds the replicated cluster state and exists on managers.
A worker has the directory and nothing meaningful in it.

**`images`** is one dataset, not one per image: content-addressed blobs plus a
small metadata file set mapping references and digests to what is on disk.

**`layers/<chain-id>`** is one dataset per applied layer chain, keyed by the OCI chain ID — the digest of the diff-ID chain — so two images that share a base share the dataset.
Each carries an `@final` snapshot taken once the layer has been unpacked into it.
Layer N is a clone of layer N−1's `@final`, which is what makes pulling a second image on a shared base nearly free.

**`containers/<task-id>`** is the container's writable layer: a clone of the top `@final` of its image.
Named for the task, because a container *is* a task.

**`volumes/<volume-name>`** is one dataset per named volume, mounted into jails with nullfs.
Volumes deliberately outlive the containers that used them — see [Volumes, binds and tmpfs](../use/storage.md).

## The rest of the state directory

```
/var/db/satl/
├── raft/
│   ├── dek                 at-rest encryption key, mode 0600
│   ├── log.redb            the raft log (entries encrypted)
│   ├── snapshot            raft snapshot (encrypted), after ~10 000 writes
│   ├── node-id             this node's cluster identity (25-char id)
│   └── raft-id             this node's raft member id
├── certs/                  mode 0700
│   ├── ca.crt              the cluster trust bundle
│   ├── node.crt            this node's certificate — its role is the OU
│   └── node.key            its private key, mode 0600
├── worker/tasks/<task-id>  the local task database: one record per assigned task
├── bundles/<task-id>/      the OCI bundle handed to ocijail, and config payloads
├── logs/<task-id>/         stdout.log and stderr.log — what `satl logs` reads
├── health/<task-id>/       healthcheck probe state, for tasks that have one
├── net/<network>.json      node-local IPAM: which task holds which address
├── ocijail/<task-id>/      ocijail's own state database (its `--root`)
├── scratch/                short-lived working space for the runtime
├── managers.json           on a worker: the manager list its session last reported
└── dispatcher.sock         on a manager: the local dispatcher socket
```

Two of these are worth a second look.

`net/<network>.json` is small and completely readable, and it is the answer to
"which container has 10.88.0.5":

```console
$ sudo cat /var/db/satl/net/satl.json
{
  "name": "satl",
  "subnet": "10.88.0.0/24",
  "allocations": {
    "2qw3gxb4uklpaowonekzukj02": "10.88.0.5"
  }
}
```

`managers.json` is how a worker finds its cluster again after a restart.
If it is lost, the daemon **refuses to start** with a message telling you to re-join rather than inventing a cluster of its own — which is the right refusal: a worker that self-initialised would become a one-node cluster running nothing.

## The `dek` file

`raft/dek` is 32 bytes, mode 0600, and it is the key that encrypts the Raft log entries and snapshots at rest.
Every secret in the cluster is inside that encryption, because the whole log is.

!!! danger "Treat `dek` exactly like a private key"

    - **Anyone who has `dek` and a copy of `raft/` has every secret in the cluster.**
      A backup of the state directory that includes it is as sensitive as the manager's disk.
    - **Anyone who has `raft/` without `dek` has nothing readable.**
      Losing the file makes that node's local Raft state permanently unreadable.
      On a cluster with several managers the node can re-sync from its peers; on a single-manager cluster the state is gone.
    - It sits beside `node.key` in trust level.
      Do not copy it around, do not put it in a git repository, do not include it in a backup you would not also trust with the TLS private key.

## Autolock: the DEK under an operator-held key { #autolock }

By default `dek` is a plain 0600 file — anyone who reads the disk has it.
`satl swarm update --autolock=true` changes that: every manager seals its DEK under a cluster-wide **unlock key** and deletes the plain file, leaving `raft/dek.sealed`.
The unlock key is printed **once**, at enable time and at each rotation:

```sh
satl swarm update --autolock=true      # prints the unlock key once
satl swarm unlock-key                  # print it again (unlocked manager)
satl swarm unlock-key --rotate         # replace it; every manager reseals
```

A locked manager boots into a locked mode: the API socket answers `503` to
everything except `/_ping` and `POST /swarm/unlock` until the key arrives:

```sh
satl swarm unlock --key '…'            # or pipe the key on stdin
```

The DEK then exists only in memory — no plain file is ever written back.
A wrong key is a 401.
Disabling (`--autolock=false`) writes the plain `dek` back on every manager.

!!! warning "The unlock key is not in any backup"

    It lives in the encrypted store — readable only after an unlock — and in whatever password manager you put it in.
    On a cluster with autolock on, **back up the unlock key alongside the raft snapshots**, or a restore is a paperweight: `dek.sealed` without the key opens nothing.
    The key survives in the store across a CA rotation; it does not survive losing the quorum's stores.

    And plan restarts: a locked manager that reboots serves nothing until someone unlocks it.
    Autolock trades unattended reboots for at-rest confidentiality — on a test cluster it is mostly a way to forget why the API answers 503.

## Crash recovery

Cluster state recovers fully from `raft/` after an unclean stop, `kill -9`
included, and the node's identity is stable across restarts — it is on disk in
`raft/node-id`, not derived from anything that could change.

Recovery is visible in the log.
On start the daemon reopens the Raft storage and re-applies the log into the state machine:

```
INFO satl_cluster::node: raft storage opened node_id=1oihjf6ers1k3v6ow4lxiy5bd
     raft_id=6418088851891314064 raft_dir=/var/db/satl/raft
INFO openraft::storage::helper: re-apply log [64..0) in 524 item chunks to state machine
```

??? note "`store transaction rejected` lines during replay are normal"

    Replay re-applies entries that were already rejected the first time — a
    write proposed from a stale version of an object, which the store refused
    then and refuses identically now:

    ```
    INFO satl_cluster::state_machine: store transaction rejected log_index=7 actions=2
         rejection=sequence conflict on task 2w8v7p35hi1fykxueuwtlmghk:
         store has version 6, caller wrote from version 5
    ```

    They are `INFO`, not warnings, because deterministic re-rejection is exactly what makes replay produce the same state machine every time.
    A burst of them at startup, one per historical conflict, is the expected shape.

Then the node reconciles what is on the host against what it believes: jails and datasets that no task claims are destroyed, containers still running are adopted, published ports are re-derived.
That pass is described in [The rc.d service](service.md#what-a-restart-does-and-does-not-touch).

## The container dataset that outlives its container

Removing a container does not always destroy its `containers/<task-id>` dataset
straight away, and **that is correct rather than a leak**.

A rootfs cannot be unmounted while the container's jail is still `DYING`, and `jail_remove(2)` does not destroy a prison — it moves it to `DYING`, where it stays until its last reference goes.
A VNET jail whose container held an open TCP connection when it was removed keeps its network stack alive until the connection's control blocks finish closing on their own timers, with no process attached.
That is **2 × `net.inet.tcp.msl`** — measured at 57.75 s with the default 30 s MSL, and 4.00 s with the MSL lowered inside the jail.
It is the open connection that costs, not TCP as such: a container that closed its connections before being removed has its dataset destroyed on the first try.

So `zfs destroy` fails, and it says *cannot unmount*, not *cannot destroy*:

```
ERROR … task_step{step="remove" task_id=1k7gm62t58pxl4mm4twkolzo3 service=ovl-a}:
  satl_agent::controller: task cleanup step failed step="destroy-rootfs"
  error=`/sbin/zfs destroy -r zroot/satl/containers/1k7gm…` failed with exit code 1;
  stderr: "cannot unmount '/var/db/satl/containers/1k7gm…': pool or dataset is busy"
```

Nothing an operator normally reaches for shows a holder: `fstat` reports zero open files on that filesystem, `procstat` finds no process, `mount -p` shows no submount, `ps -axo jid` finds nothing in the jail.
The reference belongs to the dying prison, and only one tool sees it:

```sh
jls -d -h name dying     # -d ADDS dying prisons; the `dying` column separates them
```

`satld` handles this without help, in two stages, both visible in the log:

```sh
sudo grep -a "has not finished dying"                /var/log/messages  # waiting, normal
sudo grep -a "deferring it to the periodic dataset"  /var/log/messages  # handed off
sudo grep -a "periodic sweep destroyed a container"  /var/log/messages  # reclaimed
```

The removal retries every 250 ms and asks `jls` on each failure whether a prison of that name still exists; while one does, the wait is expected.
It gives up after 30 s — not because 30 s is enough, but because a removal is applied inline on the node's assignment stream, so a minute spent waiting here is a minute in which the node applies nothing else.
The dataset is then handed to a sweep that runs every 20 s, compares the datasets on disk against the tasks the store and the worker still claim, and destroys what neither claims.
Two consecutive passes must agree before it destroys anything.

**Expect the dataset to disappear within about a minute and a half of the removal, with no restart and no intervention.**
A deferral is one `WARN` line carrying `task_id`, `dataset`, `waited_ms`, `jail_state` and the failed `zfs` command line, reported once rather than once per sweep.

If a dataset is still there minutes later, that is a different problem: check
whether its prison ever died (`jls -d -h name dying | grep <task id>`) and how
many vnodes the mount still holds (`mount -v | grep <task id>`).

!!! warning "Images and layers are reclaimed only when you ask"

    Container datasets are reclaimed as described above.
    **Image blobs and layer datasets are not**, until `satl system prune` is run — and it reclaims the node that answered it, not the cluster.
    See [Reclaiming space](../use/reclaiming-space.md) before you let a node pull for a long time.

---

## Backing this directory up

Of everything above, **`raft/` is the only part worth a backup**, and only on a manager.
It holds the entirety of the desired state — services, tasks, networks, nodes, secrets, configs, allocations — and the cluster's root CA.
Everything else in the state directory is node-local and rebuildable: images come back by pulling, containers by rescheduling, `certs/` by being re-issued from the CA inside `raft/` itself.

Three facts decide how you copy it, and the [full
procedure](../cluster/backup-restore.md) is measured rather than reasoned:

- **`raft/` is its own ZFS dataset**, so a snapshot of it is atomic and crash-consistent — which is exactly the image the log's storage engine recovers from.
  `zfs snapshot zroot/satl/raft@backup`, then read the files out of `.zfs/snapshot/backup/`.
  A `cp -Rp` of the live directory smears across the copy window instead, and a torn copy has been observed to start and run *anyway*, so "it started" proves nothing.
- **`dek` must be in the copy.**
  Without it the restored log is unreadable, and `satld` refuses to start rather than minting a new key over sealed data — which would make the state unreadable for good.
  The key is per node: another manager's `dek` does not open this one's state.
- **On a cluster that still has quorum, you may not need the backup at all.**
  A manager that lost its state is rejoined in about six seconds, and the surviving managers replicate everything back.
  The backup is for the day the *majority* goes, which is the one situation nothing inside the cluster can fix.

!!! tip "Read the procedure before you write the cron job"

    [Backup and restore](../cluster/backup-restore.md) covers taking the copy,
    restoring onto the same node, what the log says when a restore took, the
    refusals that protect you from a bad one, and the arithmetic that says how many
    managers to run and how many of them to copy.
