# Volumes, binds and tmpfs

A container's own filesystem is a ZFS clone of its image's top snapshot, and it is destroyed with the container.
Three things outlive it, and SatL supports exactly those three.

```sh
satl run -d -v appdata:/var/lib/app registry.example.com/app:1     # named volume
satl run -d -v /srv/config:/etc/app:ro registry.example.com/app:1  # bind mount
satl run -d --tmpfs /run:rw,size=64m registry.example.com/app:1    # tmpfs
```

## Volumes

A volume is a ZFS dataset at `<zfs_root>/volumes/<name>`, mounted into the jail
with nullfs.

```sh
satl volume create appdata
satl volume ls
satl volume rm appdata
```

Volumes are **node-local**, not cluster objects.
A volume exists on the node it was created on, and a task that mounts it must run on that node; nothing places a task near its data, and nothing replicates a volume.
On a cluster that means a service using a named volume needs a placement constraint pinning it to the node that holds the data, or it will be scheduled somewhere the volume is empty.

They **deliberately outlive the containers that used them**, exactly as Docker's do.
`satl rm` does not touch them; `satl volume rm` is the only thing that destroys one.
A volume still nullfs-mounted into a running jail cannot be destroyed, and the refusal says so rather than leaving you with a half-removed dataset:

```
volume 'appdata' is in use (zfs reported dataset 'zroot/satl/volumes/appdata' busy);
remove the tasks mounting it first
```

!!! info "`local` is the only driver"

    `satl volume create -d <anything but local>` is a 400.
    There are no volume plugins.
    `Scope` is always `local`, `Status` always `{}`, there is no `UsageData`, and list filters are ignored.

    Labels and driver options on a create are accepted but not persisted; they
    come back empty on inspect.

An omitted source in `-v` (`-v /data`) asks for an anonymous volume.
The flag parses, and the daemon does not create one: `?v=1` on removal is a no-op for the same reason.
Name your volumes.

## Bind mounts

```sh
satl run -d -v /srv/config:/etc/app:ro registry.example.com/app:1
```

A bind is a host path made visible inside the jail, through nullfs.
The source must be an absolute host path, the target must be absolute, and the only options are `ro` and `rw` (default `rw`).

SELinux relabelling (`:z`, `:Z`) and propagation modes (`:shared`, `:rslave`, …)
are refused with a 400 rather than accepted and ignored; there is no SELinux on
FreeBSD, and no shared subtrees.

!!! warning "A bind mount of a host path is a privilege boundary you are opening"

    Anyone who can reach the API socket can bind-mount `/` into a container and write to it.
    That is the reason [`socket_group`](../config/satld-toml.md#the-api-socket-and-who-is-allowed-to-drive-the-daemon) deserves a decision rather than a default.

## tmpfs

```sh
satl run -d --tmpfs /run:rw,size=64m registry.example.com/app:1
```

`--tmpfs /path` or `--tmpfs /path:options`, where the path is absolute and the options are passed through.
A tmpfs is memory, so it dies with the container, which is the point.

[Secrets](secrets-and-configs.md) ride their own tmpfs at `/run/secrets`, sized
to the payloads; that one is created for you and does not need a `--tmpfs` flag.

## `--mount` is refused

```console
$ docker -H unix:///var/run/satl.sock run --mount type=bind,src=/srv,dst=/srv nginx
Error response from daemon: HostConfig.Mounts is not supported by SatL:
use Binds (`src:dst[:ro]`) or Tmpfs [...]
```

`satl run` has no `--mount` flag at all, and `HostConfig.Mounts` over the API is a 400.
Use `-v` and `--tmpfs`.

On a **service**, `TaskTemplate.ContainerSpec.Mounts` is honoured for the `bind`, `volume` and `tmpfs` types over the API, but `Consistency`, `BindOptions`, `VolumeOptions`, `TmpfsOptions` and any other mount type are refused.
`satl service create` itself carries no mount flag, so mounts on a service need the REST API.

## What this costs on disk

Everything above lives under the same ZFS root, so one command is the whole
picture:

```console
$ zfs list -r zroot/satl
NAME                            USED  AVAIL  REFER  MOUNTPOINT
zroot/satl                     81.2M   683G   596K  /var/db/satl
zroot/satl/containers          1020K   683G   128K  /var/db/satl/containers
zroot/satl/images              19.0M   683G  19.0M  /var/db/satl/images
zroot/satl/layers              59.4M   683G   128K  /var/db/satl/layers
zroot/satl/volumes               96K   683G    96K  /var/db/satl/volumes
```

Container datasets are reclaimed automatically, sometimes [about a minute after the container goes](../config/state.md#the-container-dataset-that-outlives-its-container).
Volumes are reclaimed when you say so, or by `satl system prune --volumes`, which takes every volume no task mounts.
**Image layers are reclaimed only when you ask, and only on the node you ask**: see [Reclaiming space](reclaiming-space.md), because on a busy node that is the number that grows.
