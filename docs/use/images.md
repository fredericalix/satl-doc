# Images

SatL pulls OCI images from any registry that speaks the distribution API, and
turns their layers into ZFS datasets. It can also **build** FreeBSD images
itself, with `satl build` and a `Satlfile` — the pkg-shaped subset of a
Dockerfile, covered [below](#satl-build).

```sh
satl pull registry.example.com/nginx:1
satl images
```

A `satl run` or `satl service create` pulls on its own when the image is missing,
so an explicit `pull` is mostly for warming a node or for checking that a
registry and a reference work before you wire them into a service.
`satl run --pull always|missing|never` controls that (default `missing`).

## References

References are normalised the way the Docker CLI normalises them: `nginx`
becomes `docker.io/library/nginx:latest`, `alpine:3` becomes
`docker.io/library/alpine:3`, and anything with a host component is left alone.
An image is identified by its manifest digest, so `satl images` shows that digest
as the `IMAGE ID` — there is no separate content id, and no parent chain:

```console
$ satl images
REPOSITORY                               TAG      IMAGE ID       CREATED        SIZE      PLATFORM
127.0.0.1:5000/satl-test/alpine          latest   79ff19e9084a   56 years ago   3.846MB   linux/amd64
127.0.0.1:5000/satl-test/freebsd-nginx   latest   af645a19660d   56 years ago   15.63MB   freebsd/amd64
```

!!! bug "`CREATED` is not filled in"

    The daemon does not record the image config's creation timestamp, so
    `/images/json` reports `Created: 0` and the CLI faithfully renders that as
    "56 years ago" for every image. Ignore the column; it says nothing about the
    image. `SIZE` and `PLATFORM` are real.

## Which platform you get

An image reference usually points at an index (a manifest list) covering several
platforms. SatL picks one, in this order:

1. the platform you asked for with `--platform os/arch[/variant]`, which must
   exist in the index;
2. **`freebsd/<host arch>`** — a native jail, and always preferred;
3. **`linux/amd64`**, when the node has the linuxulator available;
4. otherwise an error naming what the index does offer:

```
no matching platform for freebsd/amd64, linux/amd64 (emulation) in
registry.example.com/app:1; available: [linux/arm64, linux/ppc64le]
```

The selected platform is not an implementation detail, because it decides whether
the task runs as a native jail or under Linux emulation — so it is a column of
its own in both `satl images` and `satl ps`. `--platform` takes `os/arch` or
`os/arch/variant`; the variant is accepted and ignored, and a single component
(`--platform linux`) is refused where Docker would infer the rest.

??? note "What a Linux image needs, and what it does not get"

    `linux.ko` must be loaded — `satld` probes `compat.linux.osrelease` at
    startup and says so:

    ```
    INFO satld::node: linuxulator available; linux/* images may be selected osrelease=5.15.0
    ```

    The jail gets `linprocfs` on `/proc`, `linsysfs` on `/sys`, `devfs`,
    `fdescfs` and tmpfs mounts, which is enough for glibc and musl binaries,
    `ps`, and `/proc/self/maps`. What it does not get: **cgroups, systemd and a
    PID namespace**. An image whose entrypoint is an init system is rejected at
    task creation with a message saying so, rather than half-started — systemd
    exits 1 with no output, so runtime detection would be useless.

    `uname -r` inside such a container reports `5.15.0`
    (`compat.linux.osrelease`), not the FreeBSD version, because glibc keys
    behaviour off it. And see [Resource limits](resource-limits.md) for what
    `/proc/meminfo` says.

## Registries

Every registry is contacted over HTTPS, using rustls. There is one exception and
no override:

!!! warning "Plain HTTP works for loopback registries only"

    `localhost`, `127.0.0.1` and `[::1]` — on any port — are reachable over
    plain HTTP, because that is what a local test registry needs. **Every other
    host is HTTPS, and there is no insecure-registry setting.** An explicit
    HTTP reference to anything else is refused:

    ```
    refusing plain-HTTP registry "registry.internal:5000": only localhost/127.0.0.1
    may be contacted without TLS
    ```

    There is no `satld.toml` key and no daemon flag that changes this. A
    registry on your own network needs a certificate the node trusts.

Transient failures — connection errors and 5xx responses — are retried three
times with a doubling backoff. Every blob and manifest is verified against its
digest as it is written, so a corrupted transfer fails rather than being stored.

## Authentication

Credentials travel per request, in Docker's `X-Registry-Auth` header, and
**nothing is persisted by the daemon**. There is no credential store, no
`~/.satl/config.json`, and — deliberately — no place a stolen node disk gives up
a registry password.

`satl` itself has no `login` verb. The practical paths to a private registry
are:

```sh
# a Docker CLI pointed at SatL's socket carries its own ~/.docker/config.json
docker -H unix:///var/run/satl.sock pull registry.example.com/private/app:1

# or set the header yourself
AUTH=$(printf '{"username":"u","password":"p"}' | b64encode -r -)
curl -s --unix-socket /var/run/satl.sock -X POST \
     -H "X-Registry-Auth: ${AUTH}" \
     'http://localhost/images/create?fromImage=registry.example.com/private/app&tag=1'
```

The header is accepted in standard or URL-safe base64, padded or not. Bearer
token challenges (`WWW-Authenticate: Bearer`) are negotiated automatically;
registries that answer a `Basic` challenge get the credentials directly.

!!! warning "Credentials reach an explicit pull, and not a task's own pull"

    `X-Registry-Auth` is honoured on `POST /images/create` — the explicit pull
    above, and the one `satl pull` performs. It is **accepted and then dropped**
    on `POST /containers/create` and `POST /services/create`: the task's spec
    carries no pull options, so when a node has to fetch the image itself, it
    fetches it anonymously.

    In practice: a service on a private registry works only if the image is
    already present on every node that might run it. Pull it there first
    (`satl pull` on each node, with credentials), or push it to a registry the
    nodes can read without authenticating.

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

The verbs are `FROM` (one, mandatory), `PKG`, `ENV`, `LABEL`, `WORKDIR`,
`EXPOSE`, and exec-form `ENTRYPOINT`/`CMD`. **There is no `COPY` and no build
context**: an image is the base rootfs plus packages; content goes in via a
mounted config or a later image. The shell form of `ENTRYPOINT` is refused —
it would promise a shell the image may not have.

What the build does: pulls the base into the local store, unpacks its layers,
`pkg --rootdir install` for each `PKG`, bakes `/var/run/ld-elf.so.hints` with
`ldconfig` (a jail never runs `rc`; without the hints, pkg-installed binaries
die on missing shared objects), and repacks a single-layer `freebsd/amd64`
OCI image. It runs **on the daemon's host, as root**, against the local
content store — this is not Docker's `POST /build`, which does not exist here
and answers `404`.

!!! warning "The image lands in this node's store only"

    There is no cluster-wide image distribution. A service scheduled on three
    nodes needs the image on all three: build on each, or push the result to a
    registry with `skopeo` and let the nodes pull.

Two jail facts a stateful image build runs into, both covered in
[the platform notes](../reference/out-of-scope.md#platform):

- the minimal `freebsd-runtime` base has **no PAM modules**, so privilege
  droppers like `sudo` do not work in it — run the service as a numeric
  `user:` in the compose file or `--user`, and pre-chown its volume;
- jails disable **SysV IPC** by default, which PostgreSQL cannot even
  `initdb` without — opt in per container with the labels
  `satl.jail.sysvshm=new` and `satl.jail.sysvsem=new`.

That label mechanism is general: `satl.jail.<param>=<value>` passes any jail
parameter ocijail understands through as an OCI annotation.

## Where the bytes go

```
zroot/satl/images                      blobs and metadata, one dataset
zroot/satl/layers/<chain-id>           one dataset per applied layer chain
```

Blobs land in a content-addressed store under `images`. Unpacking is separate:
each layer of the chain becomes a dataset cloned from the previous layer's
`@final` snapshot, keyed by the **OCI chain ID** — the digest of the diff-ID
chain up to that point. Two images sharing a base therefore share the datasets
for that base, and pulling the second one only materialises what actually
differs.

`zfs list -r zroot/satl/layers` is an honest picture of what images cost on a
node, including the sharing.

## Nothing reclaims a layer until you ask { #reclaiming }

!!! warning "Reclamation is manual, and it is per node"

    `satl system prune` removes unreferenced image content and unreferenced layer
    datasets. Nothing runs it for you: there is no background collector and no
    timer, so **a node that pulls new tags for long enough and is never pruned
    will fill its pool** — and the first symptom is `satld` failing to clone a
    rootfs for a container that was just scheduled onto it.

    It also reclaims **one node**: images and layers live on the node that pulled
    them, so a prune answered by one manager leaves every other node exactly as it
    was.

    ```sh
    satl system prune                                        # this node
    for n in alpha beta gamma; do ssh "$n" satl system prune -f; done
    zfs list -o name,used -s used -r zroot/satl/layers | tail
    ```

    [Reclaiming space](reclaiming-space.md) is the page for it — including why a
    layer sometimes survives the first prune and goes on the second.

!!! failure "Do not hand-delete datasets under the ZFS root"

    It is tempting to `zfs destroy` a layer that looks unused. Do not: **nothing
    reconciles that**. The image metadata store still records the layer chain,
    so the image goes on being listed and goes on being selectable, and the next
    container created from it fails at clone time with a missing-snapshot error
    that names a dataset you deleted by hand.

    `satl system prune` is the supported path precisely because it removes the
    record and the dataset together, and declines when something still holds a
    clone. Container datasets are reclaimed without being asked, by [the periodic
    dataset
    sweep](../config/state.md#the-container-dataset-that-outlives-its-container).

## What `satl images` does not do

`satl images` has `--no-trunc` and `-q` and nothing else: no `--filter`, no
`--all`, no `--digests`. Filters sent to `GET /images/json` are ignored rather
than refused.

Several fields of `/images/json` are placeholders: `ParentId` is always empty
(SatL keeps no parent chain), `Labels` is always null, `SharedSize` is always 0,
and `Created` is always 0 as noted above. `Size` is the sum of the layer sizes
and `Containers` is a real count of the tasks using the image, so those two mean
what they say.
