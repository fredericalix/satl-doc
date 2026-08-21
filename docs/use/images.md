# Images

SatL pulls OCI images from any registry that speaks the distribution API, and turns their layers into ZFS datasets.
It can also **build** FreeBSD images itself, with `satl build` and a `Satlfile`, the pkg-shaped subset of a Dockerfile, covered [below](#satl-build).

```sh
satl pull registry.example.com/nginx:1
satl images
```

A `satl run` or `satl service create` pulls on its own when the image is missing, so an explicit `pull` is mostly for warming a node or for checking that a registry and a reference work before you wire them into a service.
`satl run --pull always|missing|never` controls that (default `missing`).

## References

References are normalised the way the Docker CLI normalises them: `nginx` becomes `docker.io/library/nginx:latest`, `alpine:3` becomes `docker.io/library/alpine:3`, and anything with a host component is left alone.
A first component counts as a host only if it contains a `.` or a `:`, or is exactly `localhost`, Docker's own heuristic, which is why `127.0.0.1:5000/satl-test/x` is a registry and `freebsd-runtime:15.1` is not.

!!! warning "A bare name is a Docker Hub *library* name, and fails as an auth error"

    `freebsd-runtime:15.1` is not "the local FreeBSD base image": it normalises to `docker.io/library/freebsd-runtime`, a repository that does not exist; the FreeBSD project publishes under `freebsd/`, not `library/`.
    Docker Hub answers a missing repository with `401`, so what comes back is not "no such image" but this:

    ```
    Error response from daemon: registry docker.io: authentication failed for
    library/freebsd-runtime: credentials rejected after auth challenge
    (WWW-Authenticate: Some("Bearer realm=\"https://auth.docker.io/token\",
    service=\"registry.docker.io\",scope=\"repository:library/freebsd-runtime:pull\",
    error=\"insufficient_scope\""))
    ```

    Write the registry out: `127.0.0.1:5000/satl-test/freebsd-runtime:15.1` for [a local registry](../start/registry.md), or `docker.io/freebsd/freebsd-runtime:15.1` for the upstream one.

An image is identified by its manifest digest, so `satl images` shows that digest as the `IMAGE ID`; there is no separate content id, and no parent chain:

```console
$ satl images
REPOSITORY                               TAG      IMAGE ID       CREATED        SIZE      PLATFORM
127.0.0.1:5000/satl-test/alpine          latest   79ff19e9084a   56 years ago   3.846MB   linux/amd64
127.0.0.1:5000/satl-test/freebsd-nginx   latest   af645a19660d   56 years ago   15.63MB   freebsd/amd64
```

!!! note "Old images show the epoch as `CREATED`"

    Images pulled or built before the timestamp was read (pre-M7a) have no creation time recorded, and `/images/json` reports `Created: 0`, rendered as "56 years ago".
    Anything pulled or built since carries its real date.
    `SIZE` and `PLATFORM` are real either way.

## Which platform you get

An image reference usually points at an index (a manifest list) covering several platforms.
SatL picks one, in this order:

1. the platform you asked for with `--platform os/arch[/variant]`, which must
   exist in the index;
2. **`freebsd/<host arch>`**: a native jail, and always preferred;
3. **`linux/amd64`**, when the node has the linuxulator available;
4. otherwise an error naming what the index does offer:

```
no matching platform for freebsd/amd64, linux/amd64 (emulation) in
registry.example.com/app:1; available: [linux/arm64, linux/ppc64le]
```

The selected platform is not an implementation detail, because it decides whether the task runs as a native jail or under Linux emulation, so it is a column of its own in both `satl images` and `satl ps`.
`--platform` takes `os/arch` or `os/arch/variant`; the variant is accepted and ignored, and a single component (`--platform linux`) is refused where Docker would infer the rest.

Selecting `linux/amd64` has consequences beyond the image itself: what the host must have loaded, the mounts the jail is given, and the handful of Linux kernel features that are simply absent.
[Linux containers](linux-containers.md) is the page for all of it.

## Registries

Every registry is contacted over HTTPS, using rustls.
There is one exception and no override:

!!! warning "Plain HTTP works for loopback registries only"

    `localhost`, `127.0.0.1` and `[::1]`, on any port, are reachable over plain HTTP, because that is what [a local registry](../start/registry.md) needs.
    **Every other host is HTTPS, and there is no insecure-registry setting.**

    Nothing warns you at the reference: the scheme is chosen from the host name and the request simply goes out as TLS.
    A registry serving plain HTTP anywhere else therefore fails as a transport error, and the URL in it is the diagnosis:

    ```
    Error response from daemon: registry 10.88.0.1:5999: GET manifest 15.1 for
    satl-test/freebsd-runtime: error sending request for url
    (https://10.88.0.1:5999/v2/satl-test/freebsd-runtime/manifests/15.1)
    ```

    There is no `satld.toml` key and no daemon flag that changes this.
    A registry on your own network needs a certificate the node trusts.

Transient failures, connection errors and 5xx responses, are retried three times with a doubling backoff.
Every blob and manifest is verified against its digest as it is written, so a corrupted transfer fails rather than being stored.

## Authentication

Credentials travel per request, in Docker's `X-Registry-Auth` header, and **nothing is persisted by the daemon**.
There is no credential store, no `~/.satl/config.json`, and, deliberately, no place a stolen node disk gives up a registry password.

`satl` itself has no `login` verb.
The practical paths to a private registry are:

```sh
# a Docker CLI pointed at SatL's socket carries its own ~/.docker/config.json
docker -H unix:///var/run/satl.sock pull registry.example.com/private/app:1

# or set the header yourself
AUTH=$(printf '{"username":"u","password":"p"}' | b64encode -r -)
curl -s --unix-socket /var/run/satl.sock -X POST \
     -H "X-Registry-Auth: ${AUTH}" \
     'http://localhost/images/create?fromImage=registry.example.com/private/app&tag=1'
```

The header is accepted in standard or URL-safe base64, padded or not.
Bearer token challenges (`WWW-Authenticate: Bearer`) are negotiated automatically; registries that answer a `Basic` challenge get the credentials directly.

!!! warning "Credentials reach an explicit pull, and not a task's own pull"

    `X-Registry-Auth` is honoured on `POST /images/create`; the explicit pull above, and the one `satl pull` performs.
    It is **accepted and then dropped** on `POST /containers/create` and `POST /services/create`: the task's spec carries no pull options, so when a node has to fetch the image itself, it fetches it anonymously.

    In practice: a service on a private registry works only if the image is already present on every node that might run it.
    Pull it there first (`satl pull` on each node, with credentials), or push it to a registry the nodes can read without authenticating.

## Building a FreeBSD image: `satl build` { #satl-build }

A FreeBSD image is a base userland plus packages, and `satl build` is exactly
that pipeline, driven by a `Satlfile`:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG postgresql17-server
EXPOSE 5432/tcp
ENTRYPOINT ["/usr/local/bin/postgres", "-D", "/var/db/postgres/data"]
```

```sh
sudo satl build -t 127.0.0.1:5000/satl-test/freebsd-postgres:latest
```

The verbs are `FROM` (one or several, or `scratch`), `PKG`, `COPY`, `RUN`, `ENV`, `LABEL`, `WORKDIR`, `EXPOSE`, and exec-form `ENTRYPOINT`/`CMD`.
The shell form of `ENTRYPOINT` is refused; it would promise a shell the image may not have.

`COPY` reads from the **build context; the Satlfile's own directory**: sources are context-relative, and `..`, absolute paths and symlink escapes are refused.
A directory source copies its *contents*, as Docker's COPY does; a relative destination resolves against `WORKDIR`.
`RUN` executes `/bin/sh -c` **in a chroot of the assembled rootfs**, with the Satlfile's `ENV` and `WORKDIR`, on the build host's kernel, so build on the FreeBSD major you deploy.
All `PKG` steps run before the first `COPY`/`RUN` (a package must be installed before a step can use it); the rest execute in file order.

## `FROM scratch` and multi-stage builds

`FROM scratch` is the empty base; the image is exactly its step layers.
Several `FROM` lines define several **stages**, named with `AS` (or addressed by index); every stage builds fully, and only the last one is repacked into the image, so the toolchain stays behind in the builder stage:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1 AS builder
PKG llvm
COPY src/ /src/
RUN make -C /src

FROM scratch
COPY --from=builder /src/out /usr/local/bin/out
ENTRYPOINT ["/usr/local/bin/out"]
```

`COPY --from=<stage>` reads the earlier stage's finished rootfs, with the same escape guards as context sources, and it is cache-keyed on the copied content; a changed builder output invalidates the final stage.
Copying out of an image (`--from=registry/x:1`) is refused plainly: name or index a stage instead.

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG node24
COPY app/ /srv/app/
RUN /usr/local/bin/node --check /srv/app/server.js
EXPOSE 8080/tcp
ENTRYPOINT ["/usr/local/bin/node", "/srv/app/server.js"]
```

What the build does: pulls the base into the local store, unpacks its layers, `pkg --rootdir install` for each `PKG`, bakes `/var/run/ld-elf.so.hints` with `ldconfig`, runs the COPY/RUN steps, and repacks a `freebsd/amd64` OCI image.
The hints are baked because a jail never runs `rc`; without them, pkg-installed binaries die on missing shared objects.
It runs **on the daemon's host, as root**, against the local content store; this is not Docker's `POST /build`, which does not exist here and answers `404`.

The image is **multi-layered**: the base's layers plus one layer per mutating step (the `PKG` group, each `COPY`, each `RUN`), diffed between steps with whiteouts for deletions.
And builds are **incremental**: every step is cached content-addressed in `/var/db/satl/build-cache/`, so a rebuild with no moved input executes nothing at all, measured on this site’s own tutorial image: 51 s the first time, 7 s unchanged.
A changed file re-runs only the steps after it.
`--no-cache` forces a clean run, `--cache-dir` relocates the cache.

--8<-- "image-is-node-local.md"

```sh
sudo satl build --push -t registry.example.com/apps/web:1.2
sudo satl push 127.0.0.1:5000/satl-test/freebsd-nginx:latest   # an existing image
```

The push is client-side, like the build (there is no `POST /images/{name}/push`
on the daemon), uploads only the blobs the registry lacks, and takes credentials
as `--username` + `--password-stdin`; nothing is stored anywhere.

Two jail facts a stateful image build runs into, both covered in
[the platform notes](../reference/out-of-scope.md#platform):

- the minimal `freebsd-runtime` base has **no PAM modules**, so privilege
  droppers like `sudo` do not work in it; run the service as a numeric
  `user:` in the compose file or `--user`, and pre-chown its volume;
- jails disable **SysV IPC** by default, which PostgreSQL cannot even
  `initdb` without; opt in per container with the labels
  `satl.jail.sysvshm=new` and `satl.jail.sysvsem=new`.

That label mechanism is general: `satl.jail.<param>=<value>` passes any jail
parameter ocijail understands through as an OCI annotation.

## Why a missing image on one node is quiet, not loud { #image-locality }

The scheduler places replicas without knowing which nodes hold the image: the filter pipeline covers availability, resource reservations, constraints, platform, host ports and the per-node replica cap, and image locality is not one of them.
The agent then resolves the image **local store first**, so the node you built on runs immediately and the others go out to the registry named in the reference.
What happens next depends on what answers them, and the two cases are nothing alike:

| What the other nodes find at that reference | What you see |
| --- | --- |
| a registry that answers `404` | the task fails, terminally, with a message that names the cause: `no such manifest … the image may exist only in another node's local store` |
| **nothing listening at all** | the task retries the pull **every second, forever**, and stays in `PREPARING` |

The second case is the one that costs an afternoon, and `127.0.0.1:5000` on a node with no registry is exactly it.
A connection error is a *transient* failure by classification: the right call for a registry that is briefly down, and indistinguishable from one that was never there.
So the task never fails, the restart supervisor never fires, `satl service ls` reports `0/3` or `1/3` indefinitely, and the helpful message above is never printed.

`satl service ps <service>` shows the tasks stuck in `PREPARING`; the node's log has the pull error, once per attempt.

## Where the bytes go

```
zroot/satl/images                      blobs and metadata, one dataset
zroot/satl/layers/<chain-id>           one dataset per applied layer chain
```

Blobs land in a content-addressed store under `images`.
Unpacking is separate: each layer of the chain becomes a dataset cloned from the previous layer's `@final` snapshot, keyed by the **OCI chain ID**, the digest of the diff-ID chain up to that point.
Two images sharing a base therefore share the datasets for that base, and pulling the second one only materialises what actually differs.

`zfs list -r zroot/satl/layers` is an honest picture of what images cost on a
node, including the sharing.

## Nothing reclaims a layer until you ask { #reclaiming }

!!! warning "Reclamation is manual, and it is per node"

    `satl system prune` removes unreferenced image content and unreferenced layer datasets.
    Nothing runs it for you: there is no background collector and no timer, so **a node that pulls new tags for long enough and is never pruned will fill its pool**.
    The first symptom is `satld` failing to clone a rootfs for a container that was just scheduled onto it.

    It also reclaims **one node**: images and layers live on the node that pulled
    them, so a prune answered by one manager leaves every other node exactly as it
    was.

    ```sh
    satl system prune                                        # this node
    for n in alpha beta gamma; do ssh "$n" satl system prune -f; done
    zfs list -o name,used -s used -r zroot/satl/layers | tail
    ```

    [Reclaiming space](reclaiming-space.md) is the page for it, including why a
    layer sometimes survives the first prune and goes on the second.

!!! failure "Do not hand-delete datasets under the ZFS root"

    It is tempting to `zfs destroy` a layer that looks unused.
    Do not: **nothing reconciles that**.
    The image metadata store still records the layer chain, so the image goes on being listed and goes on being selectable, and the next container created from it fails at clone time with a missing-snapshot error that names a dataset you deleted by hand.

    `satl system prune` is the supported path precisely because it removes the record and the dataset together, and declines when something still holds a clone.
    Container datasets are reclaimed without being asked, by [the periodic dataset sweep](../config/state.md#the-container-dataset-that-outlives-its-container).

## What `satl images` does not do

`satl images` has `--no-trunc` and `-q` and nothing else: no `--filter`, no `--all`, no `--digests`.
Filters sent to `GET /images/json` are ignored rather than refused.

A few fields of `/images/json` are placeholders: `ParentId` is always empty (SatL keeps no parent chain), `Labels` is always null and `SharedSize` is always 0.
`Created` is real, 0 only for the pre-M7a images the note above is about.
`Size` is the sum of the layer sizes and `Containers` is a real count of the tasks using the image, so those mean what they say.
