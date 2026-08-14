# Status

SatL is pre-1.0 and has never been released. This page says what works, what
does not, and what is missing entirely — in terms of what you would try to do,
not in terms of internal milestones.

Everything in the first list has been exercised on FreeBSD 15.1 amd64: on a
single host, and — for anything involving more than one node — on a three-node
cluster.

## What is built

**Containers and images.** Pull from an OCI registry (including manifest lists,
with `freebsd/*` preferred and `linux/amd64` as a fallback), run, stop, kill,
remove, inspect, wait, exec, and read logs. Image layers are ZFS datasets;
applying a layer is a snapshot and a clone. Volumes are ZFS datasets or host
bind mounts. `linux/amd64` images run under the linuxulator.

**Node-local networking.** One bridge per network, one `epair` per task, a VNET
jail per container, NAT for egress and `rdr` for published ports through SatL's
own pf anchors. Container `/etc/resolv.conf` is written per container.

**A real cluster.** `satl swarm init` / `join` / `leave`, join tokens, an
embedded CA, mTLS on every internal connection, Raft membership with
quorum-safe removal, follower-to-leader write forwarding, and a scheduler with
the full filter pipeline (readiness, resources, constraints, platform, host
ports, replica caps) plus spread ranking. Both roles work: managers and
workers, with `satl node promote` and `demote` applying **live**, at a constant
pid, without disturbing running containers.

**Overlay networking.** `satl network create -d overlay`, one VNI per network,
unicast VXLAN with a Raft-distributed forwarding table, static ARP programmed
into each jail's VNET, and an embedded per-node DNS responder giving DNS
round-robin service discovery scoped to the querying task's networks. The
overlay MTU is derived from the measured underlay rather than assumed.

**Published ports**, allocated cluster-wide, and a **routing mesh**: every
*manager* answers on the port, whether or not it runs a replica — pf redirects
to a task's overlay address, on this node or another, with return-path SNAT.
The trade is Docker's own: a relayed connection loses the client address, and a
service that needs it opts into a userspace PROXY-protocol mode with a label.
Read [Publishing ports](../use/publishing-ports.md).

**Metrics.** A Prometheus `/metrics` endpoint, off by default and bound with
`metrics_addr` / `--metrics-addr`, mirroring dockerd's posture. Docker's own
series names where dockerd defines them, so off-the-shelf dashboards render;
`satl_*` for everything SatL-specific, including per-task rctl usage.

**Image builds.** `satl build` assembles a FreeBSD OCI image from a `Satlfile`
— a `FROM` line, a package list, env, labels, an entrypoint — and registers it
in the node's store. There is no daemon-side build endpoint and no `COPY`; the
format is deliberately the pkg-shaped subset of Dockerfile. See
[Images](../use/images.md#satl-build).

**Hot vertical resize.** A `service update` that changes only resource limits
or reservations does not roll the tasks: the new rctl rules are written to the
live jails and the same containers keep serving. See
[Resource limits](../use/resource-limits.md#resizing-a-live-service).

**Desired-state orchestration.** Restart policies with a max-attempts budget
that survives a leader election; rolling updates with Docker's twelve policy
flags (parallelism, delay, failure action, monitor window, max failure ratio,
stop-first/start-first) and automatic rollback on a failing update; global
services; node availability (`active`, `pause`, `drain`); node labels enforced
continuously, so editing a label moves running tasks.

**Healthchecks**, with Docker's semantics, and one deliberate difference: a
task with a healthcheck is not reported `RUNNING` until a probe passes, and a
task that goes unhealthy is stopped and replaced rather than left running. That
gate is what makes a zero-downtime rolling update possible at all. A service that
publishes a port gets [tighter probe
defaults](../use/healthchecks.md#publishing-a-port-tightens-the-defaults) —
about 10 s to leave the traffic pool instead of about 90 — because pf never probes
what it redirects to.

**Secrets and configs.** Encrypted at rest in the Raft store, delivered into a
per-task tmpfs and never written to a worker's disk, reference-counted over the
dispatcher, and refused for deletion while a service still uses them.

**Certificates that look after themselves.** Every node's certificate is
renewed automatically part-way through its validity and swapped into the live
TLS configuration without a restart. `satl ca rotate` replaces the cluster root
CA on a live cluster with no downtime — services keep serving, sessions stay
up, writes keep committing throughout.

**Compose files**, with stack semantics: `satl compose up` deploys one *service*
per compose service on a shared overlay, scheduled across the cluster, and refuses
anything outside the supported subset instead of ignoring it. See
[Compose files](../use/compose.md).

**Disk reclamation.** `satl system prune` removes stopped containers, unused
networks, unreferenced image content and unreferenced layer datasets. It is
manual, and node-local for everything that costs disk — see [Reclaiming
space](../use/reclaiming-space.md).

**Backup and restore of cluster state**, with a measured procedure: a manager's
raft directory is its own ZFS dataset, a snapshot of it restores onto that node in
seconds, and on a cluster that still has quorum a lost manager is rejoined in about
six seconds with no backup at all. Read [Backup and
restore](../cluster/backup-restore.md) before you deploy anything you care about —
in particular the part about how many managers to run.

## What is not built

| Missing | What it means for you |
| --- | --- |
| **Automatic or cluster-wide reclamation** | `satl system prune` exists, but nothing runs it for you and one run reclaims one node's images, layers and volumes. A node never pruned still fills its pool. |
| **Recovery from a lost quorum** | A cluster whose majority of managers is gone for good cannot be repaired from inside — there is no `ForceNewCluster` — and the only way back is restoring a majority from their own backups. |
| **Packages** | No FreeBSD port, no `pkg install satl`. Build from source on the host that will run it. |
| **An upgrade path** | There is no supported way to move a running cluster from one build to another. Nothing versions the on-disk state, and nothing has been tested across versions. |
| **IPv6** | SatL assigns no IPv6 addresses. `EnableIPv6` and IPv6 subnets on network creation are refused with a 400 rather than accepted and ignored. |
| **Data-plane encryption** | The control plane is mTLS everywhere; the VXLAN overlay is not encrypted. Run the underlay on a private network. |
| **Manager autolock** | No unlock key; the Raft log's at-rest encryption key sits next to it on disk, protected by file permissions. |

There is a longer, more precise list of things that are deliberately out of
scope — and why — in the [reference](../reference/out-of-scope.md).

## Rough edges you will meet

These are known, small, and none of them has a workaround worth hiding.

- **A service on a private registry cannot pull where the image is absent.** The
  registry credential is honoured for a direct `satl pull` and **dropped** on
  service create, so a node that has to fetch the image itself fetches it
  anonymously. Pre-pull on every node that may run the service, or use a registry
  the nodes can read unauthenticated. See
  [Images](../use/images.md#authentication).
- **`satl images` reports every image as created at the epoch**, so its `CREATED`
  column reads "56 years ago" for everything. The daemon does not record the image
  config's timestamp. `SIZE` and `PLATFORM` are real.
- **A stopped container keeps its jail until it is removed.** Docker keeps a
  stopped container's filesystem but not a live namespace; SatL leaves an empty
  jail (zero processes) and its epair in place. Three containers that exited two
  days ago still show up in `jls`. Harmless, unexpected, and open.
- **No `satl events` verb**, although `GET /events` is served — use `curl
  --unix-socket`.
- **Exec is not interactive.** No TTY (`-t` is a clear error, never a
  half-started container), stdin on `run -i` is not attached, and `satl exec`
  delivers its output when the process exits rather than streaming it live.
- **A few Docker service flags are missing**: `--restart-delay`,
  `--restart-max-attempts`, `--restart-window`, `--force`, `--rollback`,
  `--secret-add`/`--secret-rm`. Each has a REST API equivalent.
- **`satl kill` on a service task retires the slot for good.** The service
  drops to 0/N and stays there: kill writes the intentional-stop state, which
  the restart supervisor honours as "do not replace". Docker's kill signals the
  container and the task is replaced. To rehearse a crash, kill the jail on the
  host (`jail -r`); to bring the slot back, scale away and back or push any
  update.
- **The mesh hides the client address on relayed connections.** A connection
  answered by a manager that runs no replica is SNAT-ed through the relay, so
  the task sees the relay's address. Direct connections to a hosting node still
  show the real client, and the
  [`satl.publish.proxy_protocol=v2` label](../use/publishing-ports.md#the-client-address)
  restores it everywhere for TCP.
- **`satl network` has no `connect`, `disconnect`, `prune` or `--filter`.** The
  first two are refused by design; the others are simply absent.
- **`satl service ps <unknown service>` exits 0 with an empty table** where
  Docker errors.

## Licensing

SatL is **BSD-2-Clause**, the same terms as FreeBSD itself; every source file
carries the SPDX line. (This documentation is separately licensed CC BY 4.0.)
