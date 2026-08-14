# Your first container

From a host that has just finished [Install](install.md) to a container serving
HTTP to another machine. Every step says what it does, what breaks if you skip
it, and how to check it worked.

There is a detour in the middle that cannot be avoided honestly: there is no
public FreeBSD image that serves HTTP, so getting a serving image means making
one. That is [step 3](#3-get-an-image-that-serves-something).

## 1. Run something that exits

Before anything serves traffic, prove the whole path works — registry pull,
layer application as ZFS clones, OCI spec, jail creation, output capture, exit
code.

```console
$ satl pull docker.io/library/alpine:latest
Pulling from docker.io/library/alpine:latest
Digest: sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f (linux/amd64)
55afa1ecc21d: Already exists
Status: Downloaded newer image for docker.io/library/alpine:latest

$ satl run docker.io/library/alpine uname -a
Linux 2blf7rzo7agy 5.15.0 FreeBSD 15.1-RELEASE-p2 releng/15.1-n283596-aadd58dddcbc GENERIC x86_64 Linux
```

That is an unmodified `linux/amd64` image running under the linuxulator, which
is why `uname` reports a Linux kernel version and a FreeBSD release in the same
line. `2blf7rzo7agy` is the jail's hostname: the first twelve characters of the
task id, which is what Docker would call the short container id.

Any OCI distribution registry works — the `(linux/amd64)` on the digest line is
platform selection choosing the only platform this image offers.

**If it fails:**

| Symptom | Cause |
| --- | --- |
| `Error response from daemon:` about a missing image | the registry is unreachable — check `net.inet.ip.forwarding` and the `satl/nat` anchor; a container that cannot reach a registry is usually a host that cannot forward |
| the task reaches `PREPARING` and fails | `ocijail` is not installed, or `satld` is not running as root |
| an error naming `linux.ko` | `kldload linux`, and add `linux_load="YES"` to `/boot/loader.conf` |

The daemon's log has the failing command line and its stderr; the CLI has the
summary. Read the log:

```sh
grep -a satld /var/log/messages | tail -40
```

## 2. Look at what you just made

```console
$ satl ps -a
CONTAINER ID   IMAGE                             COMMAND      CREATED         STATUS                    PORTS   PLATFORM       NAMES
1kqlz3n8p4bd   docker.io/library/alpine          "uname -a"   2 minutes ago   Exited (0) 2 minutes ago           linux/amd64    eager_clarke
```

`eager_clarke` is a name SatL generated, because a bare `satl run` creates an
anonymous service and something has to be called something. That is not a
cosmetic detail — see [What just happened](what-happened.md).

## 3. Get an image that serves something { #3-get-an-image-that-serves-something }

!!! warning "No public FreeBSD image serves HTTP"

    The FreeBSD project's published OCI images (`freebsd/freebsd-runtime`,
    `-static`, `-dynamic`, `-notoolchain`, `-toolchain`) are userland base
    images: none of them serves anything. So to see a container serve traffic
    you need an image built somewhere.

You have three options.

**a. Use a Linux image you already have.** Anything that listens on a port
works under the linuxulator, as long as it does not expect cgroups or
`systemd`. This is the shortest path and the one to take if you just want to
see the machinery move.

**b. Build a FreeBSD nginx image with `satl build`.** A `Satlfile` is the
pkg-shaped subset of a Dockerfile — no `COPY`, no context:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG nginx
EXPOSE 80/tcp
ENTRYPOINT ["/usr/local/sbin/nginx", "-g", "daemon off;"]
```

```sh
sudo satl build -t 127.0.0.1:5000/satl-test/freebsd-nginx:latest
```

It needs root (packages are installed into the rootfs with `pkg --rootdir`,
and the linker hints are baked with a `chroot`ed `ldconfig`), a `FROM` image
already in the local store — `satl pull` it first; the reference above assumes
a loopback registry seeded with `freebsd/freebsd-runtime:15.1` — and network
access to the FreeBSD package mirror on the first run. The result registers
into the node's image store directly; the details are in
[Images](../use/images.md#satl-build).

**c. Build one somewhere else** and push it to a registry SatL can reach. A
registry over plain HTTP has to be reachable as such; SatL treats
`127.0.0.1:5000` as insecure by convention because that is where its own test
registry lives.

The rest of this page uses `127.0.0.1:5000/satl-test/freebsd-nginx:latest`.
Substitute whatever you ended up with.

## 4. Run it, published

```console
$ satl run -d -p 8080:80 --name web 127.0.0.1:5000/satl-test/freebsd-nginx:latest
2qw3gxb4uklpaowonekzukj02
```

`-d` detaches and prints the task id. `-p 8080:80` publishes: the port is
allocated in the cluster store and a `rdr` rule is installed on this node.
Every flag is in the [`satl run` reference](../reference/cli/run.md#satl-run).

**What breaks without each piece:**

- without `pf_mode = "enforce"`, the port is allocated and shown and no rule is
  installed. This is the default. Go back to
  [Install step 6](install.md#6-write-satldtoml-do-not-skip-this);
- without the `rdr-anchor "satl/*"` line in `/etc/pf.conf`, the rule is loaded
  into an anchor pf never evaluates;
- without `pf` enabled at all, `pfctl` fails and the daemon retries on its next
  pass, logging the failure each time.

## 5. Verify, in three places

**The container is running:**

```console
$ satl ps
CONTAINER ID   IMAGE                                           COMMAND   CREATED         STATUS         PORTS                  PLATFORM        NAMES
2qw3gxb4uklp   127.0.0.1:5000/satl-test/freebsd-nginx:latest   ""        2 minutes ago   Up 2 minutes   0.0.0.0:8080->80/tcp   freebsd/amd64   web
```

**The redirect really exists** — this is the check that separates "SatL thinks
it published a port" from "packets are being translated":

```console
$ pfctl -a satl/rdr -s nat
rdr pass inet proto tcp from any to any port = http-alt -> 10.88.0.5 port 80
```

`pfctl` prints `http-alt` for 8080; that is its own normalisation, not
something SatL wrote. An empty anchor reports `does not exist`, and that means
no redirect.

**The daemon agrees:**

```sh
grep -a 'loaded pf anchor' /var/log/messages | tail -2
```

## 6. The test that will not work { #6-the-test-that-will-not-work }

!!! danger "`curl localhost:8080` on the publishing host never works"

    pf applies `rdr` to packets **entering an interface**. Traffic your own host
    generates never enters one, so the redirect is not consulted. Docker on
    Linux papers over this with an iptables `OUTPUT` rule; there is no
    equivalent here, and there never was.

    Measured on this host, with the container above running and answering
    correctly:

    ```console
    $ curl -m 5 http://localhost:8080/
    curl: (28) Connection timed out after 5018 milliseconds
    ```

    It is not only `localhost`. The host's **own public address** fails the same
    way, for the same reason:

    ```console
    $ curl -m 5 http://51.38.30.173:8080/
    curl: (28) Connection timed out after 5004 milliseconds
    ```

    This is the single most reported non-bug in SatL.

Two things do work.

**From another machine**, to the host's address on the published port. This is
the real test, and it is what the published port is for:

```console
$ curl http://51.38.30.173:8080/          # from any other host
satl-test-ok
```

**From this host, to the container's own address**, on the bridge, with no
redirect involved at all:

```console
$ curl http://10.88.0.5/
satl-test-ok
```

The container's address is on the node's bridge network (`10.88.0.0/24` by
default, gateway `10.88.0.1`); `satl inspect web` prints it, and the `rdr` rule
above names it as the redirect target.

## 7. Resource limits, and the reboot you may have deferred

```sh
satl run -d --memory 512m --cpus 1.5 --name limited <image>
```

If you rebooted with `kern.racct.enable=1`, `rctl` rules are installed with the
container and removed with it — read them back with `rctl -h jail:<container
id>`. If you did **not**, the flags are accepted and nothing is enforced: no
error, no rejected request, only the warning in the startup log and a note in
the task's status message.

Note that a SatL memory limit is a **kill**, not a throttle
([why](../about/why-freebsd.md#no-cgroups-rctl-instead-and-memory-kills)).

## 8. Clean up

```sh
satl rm -f web
```

!!! warning "That removed a service too"

    `satl rm` deletes the Service behind the container, not just the container.
    It has to: leave the service and the orchestrator immediately refills the
    empty slot with a fresh task, and you have removed nothing.

    You can watch this: `satl service ls` before and after.

The container's ZFS dataset may survive the removal by up to a minute and a
half, and that is expected — a jail whose container had an open TCP connection
stays `DYING` for two maximum segment lifetimes (60 s by default) and keeps its
rootfs mounted. `satld` waits, then hands the dataset to a sweep that runs
every 20 seconds. Nothing is leaked and nothing needs doing.

Next: [What just happened](what-happened.md) — the debrief.
