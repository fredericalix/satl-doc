# What SatL does not do

Deliberate absences, honest ones, and what to do instead.
Nothing on this page is a bug; several items on it have real operational costs, and the point of listing them together is so that you meet them here rather than in production.

The two entries you should read before running SatL for any length of time are
[automatic reclamation](#no-prune) and [backup and restore](#no-backup).

## No automatic reclamation, and none across the cluster { #no-prune }

Space *is* reclaimable: `satl system prune` removes stopped containers, unused networks, unreferenced image content and unreferenced layer datasets, and [Reclaiming space](../use/reclaiming-space.md) is the page for it.
What does not exist is anything that does it for you, or anything that does it for more than one node.

!!! warning "Reclamation is manual and node-local"

    - **Nothing runs on a timer.**
      No image, layer or content-store entry is ever deleted on image removal, on service removal, or in the background.
      A node that pulls a new tag on every deploy and is never pruned will still fill its pool.
    - **One prune reclaims one node.**
      Containers and networks are cluster objects, so those are cluster-wide; images, layers, blobs and volumes are on the node whose daemon answered.
      Reclaiming a cluster means running it on every node.
    - **There is one verb.**
      No `satl image prune`, `satl container prune`, `satl network prune` or `satl volume prune`, and no `--filter`; an unknown filter is a `400` rather than a silent no-op, because on a command whose job is destroying things, ignoring a filter deletes more than the caller asked for.

What is reclaimed without being asked: a container's writable layer, when its task
is removed, possibly a minute late, by a sweep that runs every 20 s.

**What to do.**
Schedule it, per node, and watch the pool between runs:

```sh
for n in alpha beta gamma; do ssh "$n" satl system prune -f; done
zfs list -o name,used,refer -r zroot/satl
```

Do **not** reach for `zfs destroy` on a layer dataset.
Nothing reconciles that: the image metadata still records the chain, so the image goes on being listed and the next container created from it fails at clone time naming a dataset you deleted by hand.

## `satl compose` is a subset, and it is a stack { #compose-limits }

There **is** a `satl compose` (`up`, `down`, `ps`, `config`), and it has [stack semantics](../use/compose.md): one service per compose service, on an overlay, scheduled across the cluster.
That is `docker stack deploy`'s model, not `docker compose`'s, and it is forced rather than chosen: SatL has no standalone container to make.

What is deliberately not there:

- **No variable interpolation.**
  `${TAG}` and `$TAG` are refused, naming the line and column.
  There is no `.env` loading and no `${VAR:-default}` grammar.
  Substitute the values before deploying.
  (`$$` → `$` *is* applied, as Compose specifies.)
- **No merging.**
  One `-f`, no override file, no `include:`, no `extends:`.
  Docker's merge rules are intricate and a half-merge is worse than none.
- **No `build`, `pull`, `run`, `exec`, `logs`, `restart`, `stop`/`start`, `top`,
  `events`, `--wait` or `--profile`**, and `up` is always detached, a
  cluster-wide log stream needs a log broker that does not exist yet.
- **No `down -v`.**
  A volume is a node-local dataset on whichever nodes ran a task, and volume labels are not persisted, so there is no label to scope a cluster-wide removal by.
  `satl compose config` prints the names; remove them per node.
- **No secret or config created from a file.**
  Only `external: true`; a secret is immutable, so a second `up` after editing the file would silently keep the old payload.
- **The single-host half of the Compose Spec is refused, not ignored.**
  `container_name`, `scale`, `privileged`, `build`, `network_mode`, `profiles`, `extends` and about forty more each fail with the file, the key and the reason named.
  Docker's own `stack deploy` prints `Ignoring unsupported options: …` and carries on; a 200-line file that half-deployed is what this refuses.

## No daemon-side image build { #no-build }

`satl build` exists and builds FreeBSD images from a `Satlfile` (see [Images](../use/images.md#satl-build)), but it runs **client-side, on the node's host**, not in the daemon.
There is no BuildKit, no `Dockerfile` support, and no `/build` endpoint; it answers `404`.
`/_ping` carries no `Builder-Version` header for the same reason.
The Satlfile's `COPY` reads only the Satlfile's own directory, `RUN` executes in a chroot on the build host's kernel, and the image lands in the local node's store only.

**What to do for anything else.**
Build elsewhere and push to a registry SatL can pull from.
On FreeBSD, `skopeo` copies images between registries and preserves multi-platform indexes byte for byte, which matters because platform selection is exactly what those indexes are for.
Note that SatL refuses a plain-HTTP registry unless it is loopback.

## No port, no signed releases, no `satl` group { #no-packages }

SatL has no FreeBSD *port* and nothing in the official package repositories, but `make package` builds a self-contained `.pkg` (binaries, rc.d script, sample config, the `ocijail` dependency declared) that installs anywhere with `pkg add ./satl-<version>.pkg`, no repository required.
There is no signed tarball and no `pkg` upgrade channel.

There is also **no dedicated `satl` group**.
The API socket is mode `0660` owned by the user and group `satld` runs as, root, so `root:wheel` on a stock host.
The `socket_group` key in `satld.toml` is parsed and reported in the startup banner but does not change the socket's ownership, so setting it to something else has no effect on who can reach the API.

**What to do instead.**
Add operators to `wheel`, or use `sudo`.
Treat membership of that group as equivalent to root on the node: anyone who can reach the socket can run containers as root.

## No upgrade path { #no-upgrade }

There is no defined procedure for moving a running cluster from one version of
SatL to another, no compatibility statement between versions of the internal
gRPC protocol or the on-disk Raft format, and no rolling-upgrade orchestration.

**What to do instead.**
Deploy the same build to every node.
Treat a version change as a change you rehearse on a cluster you can afford to rebuild.

## No backup command, and no recovery from a lost quorum { #no-backup }

The procedure exists and is measured, [Backup and restore](../cluster/backup-restore.md), but it is `zfs`, `tar` and two cluster commands, deliberately.
What does not exist:

- **No `satl backup` verb and nothing cluster-wide.**
  A copy is per manager: the `dek` that seals a manager's raft log is generated on that node and does not open another's state, so one manager's backup is only ever useful to that manager.
- **No `ForceNewCluster`.**
  Docker's `swarm init --force-new-cluster` rebuilds a cluster from one surviving manager by discarding the other members; SatL answers `501`, permanently.
  A manager that *has* its raft state resumes on a plain restart, and one that has lost it has nothing to force from.
- **Therefore: no recovery from a permanently lost quorum, from inside the cluster.**
  Writes hang rather than fail, `satl node ls` goes on reporting every node `Ready`, a replacement manager cannot be issued a certificate, and even `service satld stop` hangs.
  The only way back is restoring a majority of the raft directories from their own backups.
- **A raft backup is only cluster state.**
  Images, layers, containers and volumes are node-local and are not in it; they come back by pulling and by rescheduling.

**What to do.**
Run **three managers and back up the raft directory of at least two of them.**
Three managers make an ordinary single failure free (a lost manager is rejoined in about six seconds, no backup involved), and the backup is for the day two of them go at once.
Two managers are strictly worse than one: quorum is 2, so losing either stops every write and leaves the survivor unrecoverable.

## The routing mesh is managers-only { #no-mesh }

`PublishMode: ingress` is a real routing mesh (every manager answers on the port and pf relays to a live task wherever it runs) **but only managers do**.
A worker holds no store replica to compute the cluster-wide pool from, so it answers a published port only when it runs a task of the service itself.

Two consequences to plan around: point any front-end load balancer at the
managers (or health-check the port, if workers must be backends), and expect a
relayed connection to carry the relay's address, not the client's, the
[`satl.publish.proxy_protocol=v2`](../use/publishing-ports.md#the-client-address)
label is the opt-in remedy for services that need it.

## Data-plane encryption is opt-in, and never for ingress { #no-encryption }

The control plane is mutual TLS everywhere, and the overlay data plane **can** be encrypted: `satl network create -d overlay --opt encrypted` wraps the network's VXLAN datagrams in IPsec ESP (AES-128-GCM), with cluster-managed keys and automatic rotation.
[Networks](../use/networks.md#encrypted) has the whole story.
What does not exist:

- **No encrypted `ingress` network.**
  Every node holds an ingress assignment, so its keyring would ship cluster-wide instead of to participants only; a truthy `encrypted` together with `Ingress: true` is a 400.
  Traffic the routing mesh relays between nodes therefore stays in cleartext; TLS inside the containers is the answer when that matters.
- **No encryption on `bridge` networks**, and none needed: bridge traffic never
  leaves the node, so there is nothing on the wire to protect.
- **No cluster-wide default.**
  Encryption is per network, chosen at creation (there is no network-update route), so a cluster can mix encrypted and cleartext overlays; the unencrypted ones stay on UDP 4789 in cleartext.
- **No encryption mid-upgrade.**
  Do not create encrypted networks while a rolling manager upgrade is in progress: a manager running the old build silently strips the encryption fields off the network object.
  Every manager must run the new build first.

**What to do for everything else.**
Whatever does not cross the overlay (client-to-published-port traffic, most obviously) is not covered by any of this.
Run the underlay on a private network you control, and put TLS inside the containers for anything that needs confidentiality end to end.

## Metrics are opt-in { #no-metrics }

There **is** a Prometheus `/metrics` endpoint, [Metrics](../use/metrics.md), but it is off until you bind it with `metrics_addr` / `--metrics-addr`, and it is unauthenticated, mirroring dockerd.
Nothing is exported anywhere else.

**What to do besides.**
The daemon log is the other observability surface, and it is structured for it: every lifecycle transition carries `task_id`, `service_id`, `node_id`, `jail_id` and `from`/`to` fields, `--log-format json` emits one object per event, and `RUST_LOG` selects per-subsystem detail.
Ship `/var/log/messages` to whatever you already run, and see [Reading the log](../trouble/reading-the-log.md) before you write parsers; one event is one line, and that property is worth verifying on your own hosts.

## No IPv6 { #no-ipv6 }

SatL assigns no IPv6 addresses.
Node-local and overlay IPAM are IPv4-only, and a network create carrying `EnableIPv6` or an IPv6 subnet is rejected with a `400` rather than accepted and quietly ignored.
`IPv6Address` is always empty in inspect output.
IPv6 forwarding on the host is not required.

**What to do instead.**
Nothing, yet.
Published ports still work over whatever the host's own addressing is; it is the container addressing that is v4-only.

## FreeBSD on amd64 only { #platform }

- **The host must be FreeBSD on amd64.**
  15.1-RELEASE and CURRENT are what SatL is built and run on; nothing else is tested, and no other architecture is built at all.
  The daemon leans on FreeBSD-specific interfaces throughout: jails, VNET, `rctl(8)`, `pf(4)`, `if_vxlan`, `devfs` rulesets, and ZFS.
- **ZFS is mandatory, not a driver among others.**
  `satld` refuses to start without its root dataset.
  Layers are datasets, applying a layer is a snapshot plus a clone, and a container's writable layer is a clone.
- **SatL implements no runtime.**
  It generates the OCI spec and drives the `ocijail` binary, which must be installed.
- **Container images may be `freebsd/*` or `linux/*`.**
  Linux images run under the linuxulator, which needs its kernel modules loaded on that node.
  Both musl and glibc images work.
- **Images expecting cgroups, systemd or a PID namespace will not work.**
  There is no cgroup filesystem, and a jail's entrypoint is never PID 1.
  An image whose entrypoint is an init system is rejected at task creation with a sentence explaining why, rather than dying silently a second later.
- SysV IPC is disabled in the jails SatL creates **by default**; opt in per container with the `satl.jail.sysvshm=new` / `satl.jail.sysvsem=new` labels (PostgreSQL needs both).
  OFD file locks return `EINVAL`, and anything needing netlink or `io_uring` fails.

## Smaller absences, in one place

| Not there | Instead |
| --- | --- |
| interactive TTY (`-t`), attach, live-streaming `exec` output | `satl logs`, and `exec` output delivered when the process exits |
| `docker cp` / archive endpoints | bind mounts and volumes |
| `commit`, `export`, `rename`, `restart`, `pause`, `update`, `top`, `stats`, `changes` |, (all answer `404`) |
| container links, `--network host`, `--network none` | one network model: the node bridge, or an overlay |
| network `connect`/`disconnect` on a running container | declare the networks in the service spec |
| server-side `?filters=` on nodes, services, networks, secrets, configs | filter client-side; the daemon answers `501` rather than silently listing everything |
| `satl events` as a CLI verb | `GET /events` is served; use `curl --unix-socket` |
| volume plugins and drivers other than `local` | ZFS datasets and host bind mounts |
| secret drivers, templating, and secret update | rotate by replacement |
