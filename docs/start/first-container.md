# Your first container

From a host that has just finished [Install](install.md) to a container serving HTTP to another machine.
Every step says what it does, what breaks if you skip it, and how to check it worked.

There is a detour in the middle that cannot be avoided honestly: there is no public FreeBSD image that serves HTTP, so getting a serving image means making one.
That is [step 3](#3-get-an-image-that-serves-something), and building one means having a base image to build `FROM`; [A local registry](registry.md) is that page, and it is worth doing before you start.

## 1. Run something that exits

Before anything serves traffic, prove the whole path works: registry pull,
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

That is an unmodified `linux/amd64` image running under the linuxulator, which is why `uname` reports a Linux kernel version and a FreeBSD release in the same line.
`2blf7rzo7agy` is the jail's hostname: the first twelve characters of the task id, which is what Docker would call the short container id.
[Linux containers](../use/linux-containers.md) is the whole story on running images built for Linux.

Any OCI distribution registry works; the `(linux/amd64)` on the digest line is
platform selection choosing the only platform this image offers.

**If it fails:**

| Symptom | Cause |
| --- | --- |
| `Error response from daemon:` about a missing image | the registry is unreachable; check `net.inet.ip.forwarding` and the `satl/nat` anchor; a container that cannot reach a registry is usually a host that cannot forward |
| the task reaches `PREPARING` and fails | `ocijail` is not installed, or `satld` is not running as root |
| `no matching platform for freebsd/amd64 in docker.io/library/alpine:latest` | the linuxulator is off, so `linux/amd64` is never a candidate. [Enable it](../use/linux-containers.md#preparing-the-host); the daemon re-probes every 10 seconds, no restart needed |

The daemon's log has the failing command line and its stderr; the CLI has the summary.
Read the log:

```sh
grep -a satld /var/log/messages | tail -40
```

## 2. Look at what you just made

```console
$ satl ps -a
CONTAINER ID   IMAGE                             COMMAND      CREATED         STATUS                    PORTS   PLATFORM       NAMES
1kqlz3n8p4bd   docker.io/library/alpine          "uname -a"   2 minutes ago   Exited (0) 2 minutes ago           linux/amd64    eager_clarke
```

`eager_clarke` is a name SatL generated, because a bare `satl run` creates an anonymous service and something has to be called something.
That is not a cosmetic detail; see [What just happened](what-happened.md).

## 3. Get an image that serves something { #3-get-an-image-that-serves-something }

!!! warning "No public FreeBSD image serves HTTP"

    The FreeBSD project's published OCI images (`freebsd/freebsd-runtime`, `-static`, `-dynamic`, `-notoolchain`, `-toolchain`) are userland base images: none of them serves anything.
    So to see a container serve traffic you need an image built somewhere.

You have three options.

**a. Use a Linux image you already have.**
Most things that listen on a port work under the linuxulator, as long as they do not expect cgroups, `systemd`, or a kernel interface the emulation lacks.
The official `nginx` image is the measured counterexample: its workers want `EPOLLEXCLUSIVE`, [which is not there](../use/linux-containers.md#where-the-emulation-stops).
This is the shortest path if you have an image you trust to be jail-friendly, and the FreeBSD build below is the one this site can vouch for.

**b. Build a FreeBSD nginx image with `satl build`.**
This is the path the rest of the site takes, and it has one prerequisite: the base image in the `FROM` line has to exist somewhere this node can pull it from.
[A local registry](registry.md) is that somewhere: a `pkg install`, one config file and one `skopeo copy`, after which `127.0.0.1:5000/satl-test/freebsd-runtime:15.1` is a real reference on this machine.
Do that page first.

A `Satlfile` is the pkg-shaped subset of a Dockerfile, `COPY` and `RUN` included, with the Satlfile's own directory as the build context:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG nginx
COPY index.html /usr/local/www/nginx/index.html
EXPOSE 80/tcp
ENTRYPOINT ["/usr/local/sbin/nginx", "-g", "daemon off;"]
```

The `COPY` line is not decoration.
nginx's default config serves `/usr/local/www/nginx`, which on a normal host is a symlink the package's post-install script creates; `PKG` installs with `pkg --rootdir`, which runs no post-install scripts, so the image has no document root and every request answers `404 Not Found`.
Copying an `index.html` there creates the directory and gives nginx something to serve.

Put the page next to the Satlfile and build:

```sh
echo "satl-test-ok" > index.html
sudo satl build -t 127.0.0.1:5000/satl-test/freebsd-nginx:latest
```

It needs root (packages are installed into the rootfs with `pkg --rootdir`, and the linker hints are baked with a `chroot`ed `ldconfig`), and network access on the first run.
The build pulls the `FROM` image from the local registry and fetches packages from the FreeBSD package mirror.
The result registers into **this node's** image store directly, under the tag you gave `-t`; it is not pushed anywhere and no other node gains it.
The details are in [Images](../use/images.md#satl-build).

**c. Build one somewhere else** and push it to a registry SatL can reach.
"Can reach" is narrower than it sounds: `localhost`, `127.0.0.1` and `[::1]` are contacted over plain HTTP on any port, and **every other host over HTTPS, with no insecure-registry override**.
A registry on your network therefore needs a certificate this node trusts; [Images](../use/images.md#registries) has the rule and what it looks like when you cross it.

The rest of this page uses `127.0.0.1:5000/satl-test/freebsd-nginx:latest`.
Substitute whatever you ended up with.

## 4. Run it, published

```console
$ satl run -d -p 8080:80 --name web 127.0.0.1:5000/satl-test/freebsd-nginx:latest
2qw3gxb4uklpaowonekzukj02
```

`-d` detaches and prints the task id.
`-p 8080:80` publishes: the port is allocated in the cluster store and a `rdr` rule is installed on this node.
Every flag is in the [`satl run` reference](../reference/cli/run.md#satl-run).

**What breaks without each piece:**

- without `pf_mode = "enforce"`, the port is allocated and shown and no rule is installed.
  This is the default.
  Go back to [Install step 6](install.md#6-write-satldtoml-do-not-skip-this);
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

**The redirect really exists**: this is the check that separates "SatL thinks
it published a port" from "packets are being translated":

```console
$ pfctl -a satl/rdr -s nat
rdr pass inet proto tcp from any to any port = http-alt -> <satl_p8080_tcp_80> port 80 round-robin
```

`pfctl` prints `http-alt` for 8080; that is its own normalisation, not something SatL wrote.
The target is a pf table rather than one address, so the same rule balances across replicas; `pfctl -a satl/rdr -t satl_p8080_tcp_80 -T show` lists its members, here the container's bridge address.
An empty anchor reports `does not exist`, and that means no redirect.

**The daemon agrees:**

```sh
grep -a -E 'published ports (reloaded|converged)' /var/log/messages | tail -2
```

## 6. The test that will not work { #6-the-test-that-will-not-work }

!!! danger "`curl localhost:8080` on the publishing host never works"

    pf applies `rdr` to packets **entering an interface**.
    Traffic your own host generates never enters one, so the redirect is not consulted.
    Docker on Linux papers over this with an iptables `OUTPUT` rule; there is no equivalent here, and there never was.

    Measured on this host, with the container above running and answering
    correctly:

    ```console
    $ curl -m 5 http://localhost:8080/
    curl: (28) Connection timed out after 5018 milliseconds
    ```

    It is not only `localhost`.
    The host's **own public address** fails the same way, for the same reason:

    ```console
    $ curl -m 5 http://51.38.30.173:8080/
    curl: (28) Connection timed out after 5004 milliseconds
    ```

    This is the single most reported non-bug in SatL.

Two things do work.

**From another machine**, to the host's address on the published port.
This is the real test, and it is what the published port is for:

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

If you rebooted with `kern.racct.enable=1`, `rctl` rules are installed with the container and removed with it; read them back with `rctl -h jail:<container id>`.
If you did **not**, the flags are accepted and nothing is enforced: no error, no rejected request, only the warning in the startup log and a note in the task's status message.

Note that a SatL memory limit is a **kill**, not a throttle
([why](../about/why-freebsd.md#no-cgroups-rctl-instead-and-memory-kills)).

## 8. Clean up

```sh
satl rm -f web
```

!!! warning "That removed a service too"

    `satl rm` deletes the Service behind the container, not just the container.
    It has to: leave the service and the orchestrator immediately refills the empty slot with a fresh task, and you have removed nothing.

    You can watch this: `satl service ls` before and after.

The container's ZFS dataset may survive the removal by up to a minute and a half, and that is expected; a jail whose container had an open TCP connection stays `DYING` for two maximum segment lifetimes (60 s by default) and keeps its rootfs mounted.
`satld` waits, then hands the dataset to a sweep that runs every 20 seconds.
Nothing is leaked and nothing needs doing.

Next: [What just happened](what-happened.md), the debrief.
