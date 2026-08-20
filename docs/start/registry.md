# A local registry

Every image reference on this site looks like `127.0.0.1:5000/satl-test/freebsd-runtime:15.1`, and that is a real address, not a placeholder.
It is a registry running on the node itself, on loopback, holding the FreeBSD base images `satl build` builds `FROM`.

This page sets one up.
[Your first container](first-container.md) step 3 and [A real application](app-node-mariadb.md) both start from it, and without it the first build fails on its `FROM` line — on a node where everything else is healthy:

```console
$ satl pull 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
Pulling from 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
Error response from daemon: registry 127.0.0.1:5000: GET manifest 15.1 for satl-test/freebsd-runtime: error sending request for url (http://127.0.0.1:5000/v2/satl-test/freebsd-runtime/manifests/15.1)
```

`error sending request` with nothing after it is what "no registry answered" looks like.
There is no such thing as a built-in registry: `127.0.0.1:5000` is only true once you make it true.

!!! info "You could point `FROM` straight at Docker Hub"

    `docker.io/freebsd/freebsd-runtime:15.1` is a perfectly good `FROM`, and if you are trying one thing once, use it — it is the same image, and `satl pull` fetches it with no registry of your own:

    ```console
    $ satl pull docker.io/freebsd/freebsd-runtime:15.1
    Pulling from docker.io/freebsd/freebsd-runtime:15.1
    Digest: sha256:7673c9e4106e295d22da6b91b6b7570dd48814e0d71811cd9d0ea1ae5be3ef96 (freebsd/amd64)
    78d645ce98ae: Already exists
    Digest: sha256:7673c9e4106e295d22da6b91b6b7570dd48814e0d71811cd9d0ea1ae5be3ef96
    Status: Downloaded newer image for docker.io/freebsd/freebsd-runtime:15.1
    ```

    The site uses a local registry for the reasons SatL's own test cluster does: builds stop depending on Docker Hub being up, on its rate limits, and on an upstream tag being rebuilt under you; and each node pulls its base image over loopback instead of the internet.
    A tag on Docker Hub is mutable — `freebsd-runtime:15.1` is rebuilt for patch releases — so "the same base image on every node" is a property you get by mirroring it once, and not otherwise.

## Why it is on loopback, and why there is one per node

SatL contacts `localhost`, `127.0.0.1` and `[::1]` — on any port — over plain HTTP, and **every other host over HTTPS**.
There is no insecure-registry flag, no `satld.toml` key, and no plan for one.

That is not a default you can lean on: the scheme is chosen from the host, before anything is dialled.
Pointed at a plain-HTTP registry on any other address, SatL sends TLS to it and the request dies with the URL it tried printed in full — the `https://` in that URL is the whole diagnosis:

```console
$ satl pull 10.88.0.1:5999/satl-test/freebsd-runtime:15.1
Pulling from 10.88.0.1:5999/satl-test/freebsd-runtime:15.1
Error response from daemon: registry 10.88.0.1:5999: GET manifest 15.1 for satl-test/freebsd-runtime: error sending request for url (https://10.88.0.1:5999/v2/satl-test/freebsd-runtime/manifests/15.1)
```

So an unauthenticated, un-TLS'd registry is a **per-node, loopback-only** thing by construction.
A shared registry on your network is a fine idea and a different job: it needs a certificate the nodes trust, and then any node can pull from it.

The consequence is worth stating before you build anything on top of it:

- `127.0.0.1:5000` means a **different registry on each node**.
  Seeding one node seeds one node.
- pushing a built image to `127.0.0.1:5000` therefore distributes it to nobody.
  It is a place to keep images, not a way to move them.

On a cluster, run this page on every node.
Same port, same repository names, same contents — that is what makes a single image reference work everywhere, and it is exactly what the three-node test cluster does.

## 1. Install the registry

```sh
pkg install docker-registry skopeo
```

`docker-registry` is the reference implementation (`registry` 2.8.3, `sysutils/docker-registry`).
`skopeo` is only used in [step 5](#5-seed-the-base-image), to copy the base image in from Docker Hub; nothing on the running path needs it.

## 2. Write its config

The package ships a `config.yml.sample` with htpasswd auth enabled.
Replace it wholesale:

```yaml title="/usr/local/etc/docker-registry/config.yml"
# Local base-image registry: loopback only, no auth, no TLS.
version: 0.1
log:
  fields:
    service: satl-registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/db/satl-registry
  delete:
    enabled: true
http:
  addr: 127.0.0.1:5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
```

Four of those lines are decisions rather than boilerplate:

- **`http.addr: 127.0.0.1:5000`** — loopback only, which is the only address plain HTTP is allowed on.
  Binding `0.0.0.0` here would publish an unauthenticated read-write registry on your network, and SatL still could not pull from it over HTTP.
- **`rootdirectory` outside `zroot/satl`** — `/var/db/satl-registry`, next to satld's state and not inside it.
  `zroot/satl` is satld's, and it gets destroyed on its own schedule (a reinstall, a `zfs destroy -r`, the reset step of a test run).
  The base images should not go with it.
- **`delete.enabled: true`** — the registry refuses delete requests unless it is set, and re-seeding a tag then leaves the old blobs behind with no way to drop them short of emptying `rootdirectory`.
- **no `auth:` block** — nothing on loopback needs credentials, and SatL's daemon does not carry any into a task's pull anyway ([Images](../use/images.md#authentication)).

Create the storage directory:

```sh
mkdir -p /var/db/satl-registry
```

## 3. Enable and start it

```sh
sysrc docker_registry_enable=YES
service docker_registry start >/dev/null 2>&1
```

The service name has an underscore (`docker_registry`); the rc.d script calls the program `registry`, so its own messages say `registry`.

!!! warning "The redirection is load-bearing over `ssh`"

    The script runs `/usr/sbin/daemon -p <pidfile> -o <logfile> registry serve <config>` — no `-f`, which is the flag that would detach the standard streams, and unlike satld's rc.d script it never passes one.
    The registry therefore **holds the stdout and stderr it was started with** for as long as it runs.

    Start it over `ssh` without redirecting them and the ssh command never returns.
    Measured on FreeBSD 15.1, three runs: bare, the session sat there until it was killed; with `</dev/null` alone, same; with `>/dev/null 2>&1`, it returned in a second.
    The registry started and kept running in all three — it is the ssh session that hangs, which is why this reads as a network problem on the first node of a provisioning run and not as a registry problem at all.

    The registry's own output is not lost: `daemon -o` is already sending it to `/var/log/docker-registry.log` (`docker_registry_logfile`), which is where you want to read it.

## 4. Verify

```console
$ curl -sf http://127.0.0.1:5000/v2/
{}
$ service docker_registry status
registry is running as pid 4075.
```

`{}` from `/v2/` is the distribution API answering "yes, and version 2 is what I speak" — `/v2/` is the base every URL SatL builds hangs off, as the error at the top of this page shows.
No output and a non-zero exit from `curl -sf` means nothing answered; `sockstat -4l | grep 5000` says whether anything is even listening.

## 5. Seed the base image { #5-seed-the-base-image }

The FreeBSD project publishes pkgbase-derived OCI images on Docker Hub.
`freebsd/freebsd-runtime` is the one to build on: core userland, `pkg` bootstrap, one ~12.6 MB layer.
(`-static`, `-dynamic`, `-notoolchain` and `-toolchain` are the other four; `freebsd/freebsd` is an empty placeholder with no tags.)

Copy it in, keeping the tag it will be known by locally:

```console
$ skopeo copy --all --dest-tls-verify=false \
      docker://docker.io/freebsd/freebsd-runtime:15.1 \
      docker://127.0.0.1:5000/satl-test/freebsd-runtime:15.1
Getting image list signatures
Copying 2 images generated from 2 images in list
Copying image sha256:6b3b15d0fc37ca45a2636f3aaea695bfb42cc1b02c895ee939bdfef87521fbd7 (1/2)
Getting image source signatures
Copying blob sha256:5326f2be061ef16dc904a758548cc31d0e9ea7cd8ff9dfe50dc79cbbb2cc4887
Copying config sha256:9a588f5a3d5ab48a250ed778c20c37ccf319d27278712fa33c94ee8cee225b43
Writing manifest to image destination
Copying image sha256:7673c9e4106e295d22da6b91b6b7570dd48814e0d71811cd9d0ea1ae5be3ef96 (2/2)
Getting image source signatures
Copying blob sha256:78d645ce98ae2543c092fbe626468f4bea0adf1282d75b86546a10f43ea438ea
Copying config sha256:90c4936754299295608ecf3e932f20611790420b3149e5b2b74b047c473f6a0d
Writing manifest to image destination
Writing manifest list to image destination
Storing list signatures
```

`--dest-tls-verify=false` is needed because the destination is plain HTTP; the source is Docker Hub and stays verified.
`--all` copies the whole index rather than one platform, so the local top-level digest is byte-identical to upstream — which is what makes platform selection behave locally the way it behaves against the Hub.

`satl-test` is the namespace SatL's test harness uses, and this site's examples use it because that is where their output was recorded.
Nothing enforces it: the repository name after the port is yours.
If you pick another one, substitute it everywhere on the following pages.

Ask the registry what it now holds:

```console
$ curl -sf http://127.0.0.1:5000/v2/_catalog
{"repositories":["satl-test/alpine","satl-test/debian","satl-test/freebsd-nginx","satl-test/freebsd-redis","satl-test/freebsd-runtime"]}
$ curl -sf http://127.0.0.1:5000/v2/satl-test/freebsd-runtime/tags/list
{"name":"satl-test/freebsd-runtime","tags":["15.1"]}
```

(That catalog is the test cluster's, seeded with more than this page asks for.
A registry seeded by the one command above answers with `satl-test/freebsd-runtime` alone.)

## 6. Prove SatL can use it

```console
$ satl pull 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
Pulling from 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
Digest: sha256:7673c9e4106e295d22da6b91b6b7570dd48814e0d71811cd9d0ea1ae5be3ef96 (freebsd/amd64)
78d645ce98ae: Downloading
78d645ce98ae: Download complete
Digest: sha256:7673c9e4106e295d22da6b91b6b7570dd48814e0d71811cd9d0ea1ae5be3ef96
Status: Downloaded newer image for 127.0.0.1:5000/satl-test/freebsd-runtime:15.1

$ satl images
REPOSITORY                                 TAG      IMAGE ID       CREATED        SIZE      PLATFORM
127.0.0.1:5000/satl-test/freebsd-runtime   15.1     7673c9e4106e   56 years ago   12.58MB   freebsd/amd64
```

`(freebsd/amd64)` on the digest line is platform selection picking the native manifest out of the index — the arm64 one is in there too, and would be chosen on an arm64 host.
"56 years ago" is the epoch: these images carry no creation timestamp, and [every image reads that way](../use/images.md#references).

You now have what [Your first container](first-container.md) step 3 assumes.

## Living with it

**Pushing your own images into it works**, and stays on this node:

```sh
sudo satl build --push -t 127.0.0.1:5000/satl-test/freebsd-nginx:latest
sudo satl push 127.0.0.1:5000/satl-test/freebsd-nginx:latest      # an image already built
```

That is useful as a place to keep a build (it survives `satl system prune`, which only touches satld's store), and useless as a way to reach another node.
For that you need a registry the other nodes can reach — see [`satl push`](../reference/cli/push.md#satl-push) and the warning below.

--8<-- "image-is-node-local.md"

**Emptying it** is a directory removal.
The registry has a `registry garbage-collect <config>` subcommand for dropping layers no manifest references, and nothing runs it for you; for a registry holding two base images, starting over is simpler:

```sh
service docker_registry stop
rm -rf /var/db/satl-registry/*
service docker_registry start >/dev/null 2>&1
```

Then re-run [step 5](#5-seed-the-base-image).

**The registry is not part of SatL.**
Nothing in `satld` starts it, checks it, or notices that it stopped; the first sign of a stopped registry is a build or a task failing to pull, with the `error sending request` message this page opened with.
It is an ordinary FreeBSD service you now run, on every node you build on.
