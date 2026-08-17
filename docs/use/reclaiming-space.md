# Reclaiming space

Image layers are ZFS datasets, and a node that pulls a new tag on every deploy accumulates them.
`satl system prune` is what reclaims them.

```sh
satl system prune                 # stopped containers, unused networks, dangling content
satl system prune -a              # ... and every image no task's spec names
satl system prune -a --volumes    # ... and every volume no task mounts
satl system prune -f              # skip the confirmation
```

There is no timer and no background collector: reclamation happens when you ask for it.
Three things about *what* it asks are worth knowing before you type it the first time, and the first is the one an operator gets wrong.

## It is node-local for everything that costs disk

!!! danger "A prune on one manager reclaims one node"

    Containers and networks are **cluster** objects, so pruning them acts on the whole cluster.
    Images, layers, blobs and volumes live on the node that pulled or created them, and a prune answered by one daemon reclaims **that daemon's node only**.

    That asymmetry is what SatL is — a task and a network are store objects, an
    image layer is a dataset on a particular disk — so both the prompt and the
    summary name the node that answered:

    ```console
    $ satl system prune
    WARNING! This will remove:
      - all stopped containers, and the service backing each one
      - all networks not used by at least one container
      - all dangling image content (blobs, manifests and configs nothing references)
      - all unreferenced image layer datasets

    Containers and networks are cluster-wide. Images, layers are reclaimed on
    alpha ONLY:
    run this on every node to reclaim the cluster.

    Are you sure you want to continue? [y/N] y
    Deleted Containers:
    2qw3gxb4uklpaowonekzukj02
    Deleted Images:
    untagged: 127.0.0.1:5000/satl-test/alpine:latest
    deleted: blob:sha256:c6b39de5b33b…
    deleted: layer:34884abbe92863fce93…

    Total reclaimed space: 14.13MB (on alpha; images, layers and volumes are node-local)
    ```

    To reclaim a cluster, run it everywhere:

    ```sh
    for n in alpha beta gamma; do ssh "$n" satl system prune -f; done
    ```

That prompt is the **only interactive thing in the whole CLI**; everything else `satl` does is non-interactive.
It is Docker's prompt, and it fails safe: `y` or `yes` (any case) proceeds, and **anything else declines — including a stdin that cannot be read at all**.
A prune that went ahead because it could not ask would be the worst possible reading of silence.

## Pruning a stopped container removes the service behind it

This surprises people, and it is the same answer [`satl rm` gives](containers-and-services.md#satl-rm-removes-the-backing-service).
A container is a task of a service.
Remove the container and leave the service, and the orchestrator refills the slot the moment the reaper frees it — so "prune the container" would *create* one.

!!! success "The safety rail is at the service, not at the container"

    A service is pruned only when **every** container of it is stopped.
    A `--replicas 3` service with one dead task keeps all three, and nothing about it is touched.

This is also what finally reclaims the jail, the epair and the writable-layer
dataset that an exited container [goes on
holding](../config/state.md#the-container-dataset-that-outlives-its-container).

## A layer can survive the first prune

!!! note "This looks like a bug and is not"

    Reclaiming a layer dataset is irreversible — only a registry can undo it — so a layer is destroyed only when **two consecutive passes**, 1.5 s apart within the one request, agree that nothing references it.
    The claim set is assembled from readings that are each momentarily incomplete at different times: the store just after a leadership change, a worker just after a restart, the image store mid-pull.
    What the second pass disagreed about is reported rather than silently skipped:

    ```
    2 layer(s) were unreferenced on only one of the two passes and were left alone.
    Run prune again to reclaim them.
    ```

There is a second, more common reason a layer survives a prune that removed its container, and it is worth stating because it also reads as a failure: **task history still names the image.**
A removed task is retained in the store's task history for a while, its spec names an image, and that image claims the layer.
So:

1. the first prune removes the containers and untags an image reference — and
   leaves the layer, correctly claimed;
2. the task reaper prunes that history;
3. a second prune untags the last reference and destroys the layer.

Measured on this host: three stopped alpine containers and their services against a running nginx that had to survive untouched.
Two invocations reclaimed 15.18 MB — the alpine layer (10.1 MB) only went on the second one.
**If a prune reclaimed less than you expected, run it again in a minute.**
Running it twice costs nothing.

## What it reclaims, and what it will not

| Object | Scope | Reclaimed when |
| --- | --- | --- |
| container | cluster | it is stopped **and** every container of its service is |
| network | cluster | no task is attached and no service asks for it — the ingress network is never pruned |
| image record | node | `-a` only, and no task's spec names it |
| image content (blob, manifest, config) | node | no image record reaches it |
| layer dataset | node | no image chain, no clone and no apply in flight claims it, **on two passes** |
| volume | node | `--volumes` only, and no task mounts it |

Three things a prune declines to do, all of them deliberate:

- **while an image pull is in flight, no content is reclaimed.**
  A blob reaches disk before the metadata that names it, so the reachable set is incomplete by construction.
  One `INFO` line says so; run it again when the pull is done.
  The layer half is protected differently and does not have to stop.
- **a layer something still holds a clone of is left alone**, with a `WARN` naming it.
  ZFS refuses this itself (`filesystem has dependent clones`) and `zfs destroy -R`, which would force it, is never used — that flag would flatten a container's writable layer along with the image layer underneath.
- **an image whose metadata is unreadable stops content reclamation for that pass** entirely, with a `WARN`.
  A record whose manifest is missing cannot say which blobs it needs, and reclaiming on that reading could delete a live layer.

??? note "Why there are no `<none>:<none>` images to prune"

    SatL's image metadata maps a canonical reference to digests and nothing else, so an image with no reference simply has no record — a dangling image *record* is unrepresentable, which is also why `satl images` never prints `<none>:<none>`.
    What a re-pulled tag leaves behind is therefore blobs, manifests and configs that nothing reaches, and **that** is what "dangling" means here: a prune without `-a` reclaims unreferenced content.
    With `-a` it additionally forgets every image record no task's spec asks for, reported as Docker's `untagged:`.

## Reading it in the log

--8<-- "ops-log-first.md"

```sh
sudo grep -a "stopped containers pruned"                  /var/log/messages
sudo grep -a "images and layers pruned on this node"       /var/log/messages
sudo grep -a "layer dataset destroyed"                     /var/log/messages
sudo grep -a "looked unreferenced on only one of the two"  /var/log/messages  # deferred
sudo grep -a "still holds a clone of it"                   /var/log/messages  # ZFS refused, correctly
sudo grep -a "pull is in flight"                           /var/log/messages
```

## The differences from Docker's prune

- **`satl system prune` is the only prune verb.**
  There is no `satl container prune`, `satl image prune`, `satl network prune` or `satl volume prune` — though all four REST endpoints exist and behave as Docker's, so `docker -H unix:///var/run/satl.sock system prune` works.
- **`--filter` is absent, and an unknown filter is a `400`.**
  `until=` and `label=` change *what gets deleted*, so accepting and ignoring them would delete more than the caller asked for.
  That is the one compatibility shortcut which cannot be taken by a command whose job is destroying things.
- **`SpaceReclaimed` for containers can be short of the truth.**
  A container's rootfs cannot be destroyed while its jail is still `DYING`, so prune reports the bytes those datasets held when it looked, and the node's periodic sweep is what actually frees them within about a minute.
  The alternative — waiting — would make a prune take a minute per stopped container.

## Do not hand-delete a layer dataset

!!! failure "Nothing reconciles a `zfs destroy` you did yourself"

    It is tempting to destroy a layer that looks unused.
    Don't.
    The image metadata store still records the layer chain, so the image goes on being listed and goes on being selectable, and the next container created from it fails at clone time with a missing-snapshot error naming a dataset you deleted by hand.

    `satl system prune` is the supported path precisely because it removes the
    record and the dataset together, in that order, and refuses when something
    still holds a clone.

What an honest picture of a node's disk looks like, including the sharing between
images:

```sh
zfs list -r zroot/satl
zfs list -o name,used -s used -r zroot/satl/layers | tail
```
