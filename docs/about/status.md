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

**Published ports**, allocated cluster-wide and redirected on each node that
runs a replica. Read [Why FreeBSD](why-freebsd.md#no-network-namespace-to-hang-a-routing-mesh-in-ingress-lite)
for what this is *not*.

**Desired-state orchestration.** Restart policies with a max-attempts budget
that survives a leader election; rolling updates with Docker's twelve policy
flags (parallelism, delay, failure action, monitor window, max failure ratio,
stop-first/start-first) and automatic rollback on a failing update; global
services; node availability (`active`, `pause`, `drain`); node labels enforced
continuously, so editing a label moves running tasks.

**Healthchecks**, with Docker's semantics, and one deliberate difference: a
task with a healthcheck is not reported `RUNNING` until a probe passes, and a
task that goes unhealthy is stopped and replaced rather than left running. That
gate is what makes a zero-downtime rolling update possible at all.

**Secrets and configs.** Encrypted at rest in the Raft store, delivered into a
per-task tmpfs and never written to a worker's disk, reference-counted over the
dispatcher, and refused for deletion while a service still uses them.

**Certificates that look after themselves.** Every node's certificate is
renewed automatically part-way through its validity and swapped into the live
TLS configuration without a restart. `satl ca rotate` replaces the cluster root
CA on a live cluster with no downtime — services keep serving, sessions stay
up, writes keep committing throughout.

## What is not built

| Missing | What it means for you |
| --- | --- |
| **`satl compose`** | There is no way to declare a multi-service stack in a file. Every service is created with a `satl service create` command. |
| **`satl build`** | SatL runs images; it cannot make one. You need another machine, another tool, or the scripted path in [First container](../start/first-container.md#3-get-an-image-that-serves-something). |
| **`satl system prune` and layer GC** | Nothing reclaims image layers or content automatically. A registry you pulled from twice leaves both sets of datasets under `zroot/satl/layers` until you `zfs destroy` them by hand. On a long-lived node this grows without bound. |
| **Packages** | No FreeBSD port, no `pkg install satl`. Build from source on the host that will run it. |
| **An upgrade path** | There is no supported way to move a running cluster from one build to another. Nothing versions the on-disk state, and nothing has been tested across versions. |
| **Backup and restore** | The manager state directory is documented, and the encryption key that makes it readable is documented, but no restore procedure has been written or tested. Treat a SatL cluster as reproducible, not recoverable. |
| **IPv6** | SatL assigns no IPv6 addresses. `EnableIPv6` and IPv6 subnets on network creation are refused with a 400 rather than accepted and ignored. |
| **A routing mesh** | See above: published ports answer only on nodes running a replica. |
| **Metrics** | No Prometheus endpoint. The log is the observability surface. |
| **Manager autolock** | No unlock key; the Raft log's at-rest encryption key sits next to it on disk, protected by file permissions. |

There is a longer, more precise list of things that are deliberately out of
scope — and why — in the [reference](../reference/out-of-scope.md).

## Rough edges you will meet

These are known, small, and none of them has a workaround worth hiding.

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
- **`satl network` has no `connect`, `disconnect`, `prune` or `--filter`.** The
  first two are refused by design; the others are simply absent.
- **`satl service ps <unknown service>` exits 0 with an empty table** where
  Docker errors.

## Licensing

SatL itself currently ships **no LICENSE file**, so its licensing is
undetermined. Nothing on this site should be read as granting a licence to the
software. (This documentation is separately licensed CC BY 4.0.)
