# What just happened

A debrief. You ran three or four commands; the daemon created rather more than
that. Everything below is what a working single-node SatL host actually looks
like, read off one.

## Datasets

`satld` created five children under the root dataset you made, on its first
start, and has been adding one per image layer and one per container since.

```console
$ zfs list -r zroot/satl
NAME                                                    USED  AVAIL  REFER  MOUNTPOINT
zroot/satl                                             81.2M   683G   596K  /var/db/satl
zroot/satl/containers                                  1020K   683G   128K  /var/db/satl/containers
zroot/satl/containers/2qw3gxb4uklpaowonekzukj02          428K   683G  49.3M  /var/db/satl/containers/2qw3gxb4uklpaowonekzukj02
zroot/satl/images                                      19.0M   683G  19.0M  /var/db/satl/images
zroot/satl/layers                                      59.4M   683G   128K  /var/db/satl/layers
zroot/satl/layers/d5f1a01abe3517f7e9d812e4afad462a...   49.7M   683G  49.3M  /var/db/satl/layers/d5f1a01abe3...
zroot/satl/raft                                        1.11M   683G  1.11M  /var/db/satl/raft
zroot/satl/volumes                                       96K   683G    96K  /var/db/satl/volumes
```

- **`layers/`** — one dataset per image layer, named by its chain id. Applying
  a layer is: clone the parent's snapshot, unpack the layer's tar into it,
  snapshot. A second image sharing a base layer reuses the same dataset.
- **`containers/`** — one dataset per task, cloned from the top layer's
  snapshot. `REFER 49.3M` against `USED 428K` is the clone doing its job: the
  container sees a 49 MB filesystem and occupies 428 KB.
- **`images/`** — the content store: manifests, configs, blobs.
- **`raft/`** — the cluster store. On a manager this holds `log.redb`, the
  snapshot, the node and raft ids, and `dek`: the key that encrypts the log and
  snapshots at rest. Protect `dek` like a private key; without it the local
  cluster state is unreadable.
- **`volumes/`** — one dataset per named volume.

!!! warning "Nothing reclaims layers"

    There is no `satl system prune` and no layer garbage collection. Pulling ten
    tags of an image leaves ten sets of layer datasets, forever, until you
    `zfs destroy` them yourself. This is the most likely way a long-lived SatL
    host fills its pool.

## Interfaces

```console
$ ifconfig satl0
satl0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
	description: satl:network:satl
	inet 10.88.0.1 netmask 0xffffff00 broadcast 10.88.0.255
	member: epair3a flags=143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>
	groups: bridge satl
```

`satl0` is the node's default bridge network — one bridge per SatL network,
named from `network_name` in `satld.toml` with a `0` suffixed. Its address,
`10.88.0.1`, is the gateway every container on it routes through, carved out of
the `10.88.0.0/16` pool a `/24` at a time.

Each container gets an `epair(4)`: the `a` end joins the bridge, the `b` end is
moved into the jail's VNET, addressed, and given a default route to `.1`.

The **`description` field is the important part**. It is how SatL recognises
its own interfaces after an interrupted teardown — the interface *group*
(`satl`) is lost when an epair end moves into a VNET or when its jail dies,
while the description survives both. An interface with a description SatL
cannot parse completely is classified as unowned and is never destroyed, so a
future daemon adding a new marker form cannot be swept by an older one.

## pf

```console
$ pfctl -a satl/nat -s nat
nat on ice0 inet from 10.88.0.0/24 to any -> (ice0) round-robin

$ pfctl -a satl/rdr -s nat
rdr pass inet proto tcp from any to any port = http-alt -> 10.88.0.5 port 80
```

The `nat` rule is what gives containers outbound connectivity, and the
parenthesised `(ice0)` makes pf re-evaluate the interface's address — so the
rule survives a DHCP renewal or an interface that comes up late. The `rdr` rule
is your published port.

Neither is edited incrementally. SatL regenerates the entire contents of an
anchor and reloads it whenever the desired set changes, and re-asserts it
unconditionally about once a minute — because what the daemon remembers is what
it *loaded*, not what the kernel *holds*. Flush `satl/rdr` by hand in a root
shell and it comes back within a minute rather than never.

## Jails

```console
$ jls -h jid name host.hostname path
jid name                      host.hostname path
6   2qw3gxb4uklpaowonekzukj02 2qw3gxb4uklp  /var/db/satl/containers/2qw3gxb4uklpaowonekzukj02
```

One jail per task. The jail's **name is the full 25-character task id**, its
**hostname is the first twelve characters** — Docker's short id — and its path
is the container's ZFS clone. That naming is deliberate: it makes every host
tool (`jls`, `jexec`, `rctl`, `ps -J`) greppable by the same id the CLI, the
API and the log all print.

!!! note "A stopped container keeps its jail"

    Containers that have exited still appear in `jls`, holding an empty jail
    (zero processes) and its epair, until you `satl rm` them. Docker keeps a
    stopped container's filesystem but not a live namespace. This is a known
    rough edge, not a leak: the reconciliation pass accounts for these, and
    removal destroys them.

## What `satl ps` is really showing

```console
$ satl ps
CONTAINER ID   IMAGE                                           COMMAND   CREATED   STATUS         PORTS                  PLATFORM        NAMES
2qw3gxb4uklp   127.0.0.1:5000/satl-test/freebsd-nginx:latest   ""        ...       Up 2 minutes   0.0.0.0:8080->80/tcp   freebsd/amd64   web
```

Read that row again knowing what it is made of:

- **`CONTAINER ID` is a task id**, base36 and 25 characters, truncated to
  twelve here. Not a 64-character hex digest.
- **`NAMES` is the service's name**, not the container's. There is no separate
  container name.
- **`STATUS` is derived from the task state machine.** `starting` and `running`
  both render as Docker's `running`; `complete`, `shutdown` and `failed` all
  render as `exited`. `paused` and `restarting` never occur. If the service has
  a healthcheck, a task that has started but not yet passed a probe shows
  `Up 2 seconds (health: starting)` — and is deliberately invisible to DNS and
  to a rolling update until it does.
- **`PLATFORM` is SatL's own column**, not Docker's. It is the platform actually
  selected from the image's manifest list.
- **`PORTS` shows host-mode bindings only.** A container published in *ingress*
  mode — which is what `satl service create --publish` gives you — shows an
  empty `PORTS` column on a node that is actively redirecting that port to it.
  Read `satl service ls` or `pfctl -a satl/rdr -s nat` for ingress publishing.
- **One row per slot.** Retained task history from restart attempts is not
  listed as extra containers, so a replica that has crashed six times is one
  row, not seven.

## Why `satl rm` removed a service

Because there was one, and there always is.

```console
$ satl service ls
ID             NAME             MODE         REPLICAS   IMAGE                                           PORTS
2kjm40q4jy14   web              replicated   1/1        127.0.0.1:5000/satl-test/freebsd-nginx:latest   *:8080->80/tcp
1qb4wykhu6fw   hopeful_rhodes   replicated   0/1        127.0.0.1:5000/satl-test/alpine
```

`web` came from `satl run --name web`. `hopeful_rhodes` came from a bare
`satl run` that has since exited — the generated name is what a service gets
when you did not name one.

Every container in SatL is a task of a service; `satl run` creates an anonymous
single-replica service and lets the ordinary machinery place it. So removing
the container has to remove the service too. If it did not, the reconciliation
loop would compare "this service wants one replica" against "this service has
zero", and put a fresh container exactly where you just removed one. You would
have removed nothing.

This is also why there is no way to restart a stopped container: a task is
one-shot, and running it again means a *new* task with a new id — something
Docker's API has no way to express. `satl run` again is the answer for a
one-off; a service with a restart policy is the answer for anything that should
stay up.

## Where to go next

Three directions, and they are genuinely independent.

- **Use it properly on one machine** — services rather than `satl run`,
  volumes, networks, healthchecks, secrets, and what each of the CLI verbs
  actually does: [Using SatL](../use/index.md).
- **Add machines** — join tokens, managers and workers, quorum arithmetic,
  overlay networks and what published ports mean across a cluster:
  [Clustering](../cluster/index.md).
- **Tune the daemon** — all thirteen `satld.toml` keys, the pf modes, addresses
  and pools: [Configuration](../config/index.md), and the
  [`satld.toml` reference](../reference/satld-toml.md).

When something does not work, the answer is almost always in the daemon's log
rather than in the CLI's error: [Troubleshooting](../trouble/index.md).
