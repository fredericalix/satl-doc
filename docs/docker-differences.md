# Differences from Docker

SatL serves the Docker Engine API and speaks to the Docker CLI, and most of what
you know transfers. The differences are not scattered: almost all of them fall
out of one design decision and one policy.

**Every container is a task of a service, and the cluster is always on.** There
are no standalone containers and no "before you `swarm init`" mode — a fresh
daemon has already initialised a single-node cluster, and `satl run` creates an
anonymous single-replica service behind your back. A container is therefore
one-shot and immutable, it has an orchestrator watching it, and its identity is
a task ID rather than a 64-hex container ID.

**SatL refuses what it cannot honour, rather than accepting it and doing
nothing.** Where Docker has an option that has no meaning on FreeBSD jails, the
API answers `400` with a sentence naming the reason. This is deliberate and it
is mostly about isolation: a caller who passes `--security-opt` and receives a
`200` will reasonably believe something is enforced. **A half-honoured isolation
flag is a security trap.** The cost is that a Docker command line that "worked"
against another engine sometimes fails here — loudly, and with the alternative
named.

Everything below is organised by what you are trying to do.

## You look for `swarm init`

- **There is nothing to initialise.** A fresh `satld` self-initialises a
  single-node cluster on first boot: `docker info` reports
  `Swarm: active` with `ControlAvailable: true` from day one, where Docker
  reports `inactive` until you run `swarm init`.
- `satl swarm init` still exists and is **idempotent** — it re-initialises an
  existing cluster rather than failing. What it will not do is change the
  advertise or listen address: that is pinned in
  [`satld.toml`](reference/satld-toml.md) and applying it is a restart, not a
  request, so passing `--advertise-addr` is refused with a pointer to the file.
- Consequence: on a multi-node cluster, **set the advertise address in the
  config file before the first start**. Otherwise the node advertises the
  interface carrying its default route, which on a cloud instance is usually the
  public NIC rather than the private underlay you meant.
- Join tokens are spelled `SATL-1-<digest>-<secret>`. Tooling that
  pattern-matches Docker's `SWMTKN` will not recognise them.
- The internal protocol binds **two** ports, `2377` and `2378`, where Docker
  uses `2377` alone. See [Ports and firewall](reference/ports.md).

## You run a container

- **`docker start` on a stopped container is refused.** A task is one-shot: a
  restart would be a new task, which means a new container ID, which the API has
  no way to express. `start` therefore works only on a container that was created
  and never started.
- **`docker rm` removes the backing service too.** Otherwise the orchestrator
  would immediately refill the slot with a fresh task.
- **`docker stop -t` is ignored** — the grace period lives in the task spec,
  which is immutable after creation — and `docker kill --signal` is not
  forwarded: `kill` maps onto a graceful shutdown honouring the task's stop
  signal, its grace period, and then `SIGKILL`.
- The container `Id` is SatL's 25-character base36 task ID, and `Names` is
  `["/<service name>"]`. A name must satisfy the *service* naming rule, so **dots
  are rejected** where Docker accepts them.
- `docker ps` shows the newest task per slot. Retained restart history is not
  listed as extra containers, and there is an extra `PLATFORM` column, because
  on this platform "which of `freebsd/amd64` and `linux/amd64` did this actually
  resolve to" is a question you ask constantly.
- `paused` and `restarting` never occur. `Paused`, `Restarting` and `OOMKilled`
  are always false.
- There is **no TTY**: `-t` is a clear error rather than a half-started
  container, and `exec` reads and discards stdin and delivers its output when
  the process exits rather than streaming it live. `satl wait` exits with the
  container's exit code, where `docker wait` prints it and exits 0.

## You publish a port

- **`ingress` publishing is not a routing mesh.** The port is allocated
  cluster-wide, exactly as SwarmKit allocates it, and then redirected **on each
  node that runs a task of the service, to that node's own task**. A node running
  no replica does not answer on the port at all.
- Consequence: **a load balancer in front of the cluster must health-check the
  port**, not assume every node serves it. A node with no replica is not a
  degraded backend; it is a correct one. A service scaled to fewer replicas than
  there are nodes is not reachable everywhere.
- Consequence: there is no second hop, so **the source address a container sees
  is the real client's**.
- **A published port is not reachable from the publishing host via
  `localhost`.** pf applies `rdr` to packets *entering* an interface, never to
  locally generated traffic; Docker on Linux papers over this with an iptables
  `OUTPUT` rule and there is no equivalent here.
- Publishing requires `pf_mode = "enforce"` in `satld.toml` **and** pf enabled on
  the host. With the default `check`, ports are allocated and displayed and no
  redirect is installed.
- **An ingress-published container shows no port in `ps`/`inspect`**, even on a
  node that is redirecting one — the port status field carries host-mode bindings
  only, exactly as SwarmKit reports them. Read the *service* for ingress
  publishing, or `pfctl -a satl/rdr -s nat` for what a node actually redirects.
- Port ranges (`8000-8010`) are rejected, `sctp` is not supported, and
  `-p ip:host:container` accepts the address, warns, and publishes on all of
  them.

## You expect a service VIP

- **There is none.** `Endpoint.VirtualIPs` is always empty and
  `EndpointSpec.Mode: "vip"` is a `400`. Service discovery is DNS round-robin:
  a service name resolves to its running tasks' addresses, shuffled per query.
  There is no IPVS on FreeBSD.
- Consequence: clients that resolve once and cache forever will pin themselves
  to one replica. Long-lived connections do not rebalance.
- Only `RUNNING` tasks are answered, which is what makes healthchecks matter
  here (below).
- Resolution is scoped to the querying task's networks and searched in the order
  **the service spec declares them** — Docker sorts endpoints by an undocumented
  gateway-preference rule. A name present on two of a task's networks is answered
  from the first that holds it, whole, never merged with the other.
- The qualified `<name>.<network>` form is not implemented. An unqualified name
  is the only form, so **a service must be uniquely named across a task's
  networks** to be addressable unambiguously.

## You create a network

- **`Scope` follows the driver, always**: `overlay` → `swarm`, `bridge` →
  `local`. A create whose scope contradicts its driver is a `400`, not a network
  with the other scope. `local` is accepted as a synonym for `bridge`.
- **Docker's predefined `bridge`, `host` and `none` networks do not exist.** The
  list holds store objects only, and the node's own bridge is not one of them.
  `NetworkMode` on container create still accepts `bridge`/`default`/`satl`.
- **An overlay network's gateway is per node, not cluster-wide.** `inspect`
  reports *this* node's gateway, and a node running no task on the network
  reports no gateway at all. Every participating node's bridge sits on one L2
  segment, so a single shared gateway address would be a duplicate address on
  that segment — with the jails' default route and their DNS server both landing
  on whichever host won the ARP race.
- There is an extra `Vni` field on overlay networks: the VXLAN network
  identifier the allocator assigned.
- **`connect` and `disconnect` are refused** (`501`). A task's attachments are
  allocated once, at creation, and its spec is immutable, so hot-plugging a
  network means replacing the task — i.e. a different container ID than the one
  you named.
- Rejected with `400` rather than accepted and ignored: `EnableIPv6` and any
  IPv6 subnet, `Internal`, `Attachable`, `ConfigOnly`/`ConfigFrom`, any driver
  option map, `IPAM.Options`, more than one IPAM config entry, and a second
  `ingress` network.
- **Removing a network in use is a `409`**, and "in use" includes a service whose
  task template merely references it — its next task could not be placed.
  Terminal tasks do not block removal, where Docker counts a stopped container's
  endpoint.

## You set resource limits

- `--memory` becomes an `rctl(8)` rule that **kills** the process when the jail's
  resident set exceeds the cap. `--cpus` becomes a `pcpu` rule that **throttles**
  toward the cap on a decaying average, so the cap is approached rather than
  imposed instantly.
- **Enforcement needs `kern.racct.enable=1`, which is a boot-time tunable.** With
  accounting off, both flags are accepted and enforced by nothing; the daemon
  says so loudly at startup and records the reason in the task's status.
- **Limits never influence placement.** Only *reservations* do. A node with no
  free memory will still accept a task with a `--memory` limit and no
  reservation.
- Docker's other knobs are refused with the alternative named: `CpuShares`,
  `CpuQuota`, `CpusetCpus`, `MemorySwap`, `Ulimits`, `CgroupParent`, `ShmSize`.
- Inside a Linux container, `/proc/meminfo` and `/proc/cpuinfo` report the
  **host's** resources, so JVM- and Go-style automatic sizing sees the whole
  machine regardless of the limit.

## You add a healthcheck

- The semantics are Docker's — the defaults, the consecutive-failure counting,
  the start period, the bounded log. What health *does* is different, because a
  container here is a task.
- **Health gates the task state machine.** A task with a healthcheck is not
  reported `RUNNING` until a probe passes; it stays `STARTING`, rendered as
  Docker's `running` with `Status` "Up 2 seconds (health: starting)". That is the
  point: the DNS responder only answers with `RUNNING` tasks and a rolling update
  only promotes on observed `RUNNING`, so neither can send traffic to a container
  that has not passed a probe.
- **An unhealthy task is stopped and `FAILED`**, and the restart supervisor
  replaces it under the service's restart policy. Docker leaves an unhealthy
  container running, and its `--restart` never reacts to health at all.
  Consequence: a container that never becomes healthy *fails* rather than
  staying `starting` forever. `start_period` is the only grace.
- **The image's own `HEALTHCHECK` is not inherited.** Only the healthcheck in the
  spec is honoured, and Docker's "inherit from the image" marker means "no
  healthcheck" here.
- `State.Health` is **node-local**: it appears only when the node answering the
  request is the one running the task, and it never enters the cluster store or a
  task document. It is not persisted either — after a daemon restart, an adopted
  running task starts again at `starting` and is re-probed.
- `Healthcheck.StartInterval` is not supported; during the start period SatL
  probes on `min(interval, 5s)`, which is Docker's own default for it.

## You roll out an update

- **A flag you do not pass keeps the value the service already has.** `update`
  reads the stored spec, changes what you named, and posts the whole document
  back. But **naming one flag of a half names that whole half**: a service with
  no policy at all, updated with a lone `--update-monitor 30s`, gets the defaults
  for the other five fields of `UpdateConfig`, because parallelism 0 means
  "replace every slot at once" and must never be arrived at by omission.
- **An update takes at least `Monitor` per batch.** SwarmKit starts the next
  batch as soon as the previous task reaches `RUNNING` and watches for failures
  in the background; SatL makes the observation window part of the batch. With
  the defaults that means a six-replica update takes at least 30 s. Set a small
  `--update-monitor` to get SwarmKit's pace back.
- **A paused update is resumed by pushing a corrected spec** — any update clears
  the paused status, including one that changes nothing. The service does not
  have to be removed and recreated.
- **`PreviousSpec` is cleared by an automatic rollback**, exactly as SwarmKit
  clears it, so `?rollback=previous` has nothing to return to until the next
  update. The spec that just failed is not a target.
- `satl service create`/`update` do not stream progress: they print the ID and
  return, like `docker service create -d`.
- Two Docker flags are missing: `--rollback` (a manual rollback needs the REST
  endpoint) and `--force`. `satl service create` also lacks `--restart-delay`,
  `--restart-max-attempts` and `--restart-window` — a non-default restart policy
  has to be created over the API.

## You use secrets and configs

- The verbs and shapes are Docker's. What differs is where the payload goes and
  what it may be.
- **A secret's target must be a relative path**, materialised under
  `/run/secrets/<name>` on a per-task tmpfs. Docker allows an arbitrary absolute
  path and bind-mounts the file there; a secret written anywhere else would be a
  secret on disk, and secrets never touch a worker's disk here. Config targets
  may be absolute, as Docker's are.
- **`/run/secrets` is not remounted read-only.** The protection is the file mode
  (`0444` by default) and ownership, not the mount flag: an unprivileged process
  in the jail cannot alter them, root inside the jail can.
- **`File.UID`/`File.GID` must be numeric.** Docker resolves user and group
  *names* from the image's `/etc/passwd`; SatL does not read the image's user
  database, so a name is refused when the task is planned rather than silently
  owned by root.
- **Update is a `501`, with the rotation recipe in the message.** Docker's
  endpoint accepts a whole spec and honours only a change of labels — a `200`
  that silently ignored the `Data` you just sent is the worst of the three
  possible answers. Rotate by creating a new secret, updating the services, and
  removing the old one.
- **Deleting a referenced secret is a `409`** naming the services to fix first,
  where Docker answers `400`. "In use" is wider than Docker's check: it includes
  every service whose task template merely references the object.
- Secret drivers and templating are `400`s: there are no plugins and no template
  engine, and a config whose placeholders were never expanded is a broken file
  delivered as a correct one.

## You run something on a worker

- **Cluster-scoped endpoints answer Docker's own refusal**, verbatim, with
  Docker's `503`: `service`, `node`, `task`, `swarm` — and **all** of `network`,
  because a SatL network is a store object even when its driver is `bridge`, so
  a worker has no network list to serve where a Docker worker still lists its
  local ones.
- **Container lifecycle mutations are refused too** — create, start, stop, kill,
  rm, and therefore `satl run`. Docker allows these, because a Docker worker
  still runs standalone containers. SatL has none: every container is a task, and
  a task mutation is a store write a worker cannot propose.
- **Container reads work**, served from the node's local task records: `ps`,
  `inspect`, `logs`, `wait`, `exec`. Volumes and images are node-local and
  unchanged.
- `GET /events` on a worker carries local events only (image pulls). Task state
  transitions are store writes and are emitted on managers.

## You read the cluster's state

Two things the CLI prints are not what the cluster is doing, and neither is a
transient:

- **`satl node ls`'s `MANAGER STATUS` is written when the cluster forms and
  never refreshed.** After a leader dies, every node goes on calling it `Leader`
  — permanently, including after it rejoins as a follower — while Raft's real
  leader has moved. No API surface reports the live Raft leader either. Do not
  pick a node to act on from that column; read leadership from the daemon log
  ([how](trouble/cluster.md#stale-manager-status)). The `STATUS` column
  (`Ready`/`Down`) *is* maintained.
- **`satl service ps <unknown service>` exits 0 with an empty table**, where
  Docker errors with `no such service`. The task list is filtered by name and an
  unknown name matches nothing, so the daemon answers `200` with an empty list.
  An empty table means "no tasks matched", not "this service has no tasks".

One more that is correct but reads as a bug: `satl service ls` can legitimately
show **more running replicas than wanted** — `8/6` — while a node is down. A task
on a node that stopped answering keeps its last reported `Running` state, because
nothing can report otherwise, while the manager has already scheduled a
replacement.

## You point existing tooling at the socket

- Any Docker CLI works: `docker -H unix:///var/run/satl.sock version`. The API
  target is Engine v1.43, negotiable down to 1.24.
- `Server: SatL/<version>` instead of `Server: Docker/<version> (linux)`, and
  `/version` carries no `GoVersion` or `Experimental` — SatL is not Go, and the
  Docker CLI renders the missing fields as empty.
- `/_ping` has no `Builder-Version` header and `Docker-Experimental` is always
  `false`. `/info` is a minimal coherent subset: `Driver` is always `zfs`, and
  the logging-driver, registry-config and plugin fields are absent.
- **`?filters=` is answered honestly rather than ignored.** A non-empty filter on
  nodes, services, networks, secrets or configs is a `501`, so a client that
  filters server-side gets an error instead of a full, unfiltered list it thinks
  is filtered. Tasks do support filtering, on `id`, `name`, `service`, `node`,
  `desired-state` and `label`; any other key is a `400`.
- A wrong HTTP method on a known path returns an empty-body `405`, where Docker
  returns a JSON error body. `501 Not Implemented` is used for "not implemented
  yet" where Docker would typically answer `400` or `500`.
- Logs are always multiplexed, even for a container created with `Tty: true`,
  and `?since=` is ignored: the raw log files carry no per-line timestamps, so
  `timestamps=1` stamps read time. `/events` has no replayable history.

## What is not there at all

Answered as `404 page not found` rather than half-implemented: `attach`,
`commit`, `export`, `rename`, `restart`, `pause`/`unpause`, `update`, `top`,
`stats`, `changes`, `archive`, `build`.

Beyond the API: no `satl compose`, no `prune` of any kind, no image or layer
garbage collection, no metrics endpoint, no IPv6, no overlay data-plane
encryption, and no full routing mesh. Those and their consequences are on their
own page — [What SatL does not do](reference/out-of-scope.md) — because several
of them have operational costs you should know about before you run SatL for
long.

---

!!! info "The exhaustive list lives in SatL's source tree"

    This page is the shape of the differences, chosen for what a Docker user
    trips over. Every intentional deviation is recorded, numbered and dated in
    `docs/api-compat.md` in the SatL repository, in the same change that
    introduced it — that file is the contract, and it is where to look when you
    need the exact wording of a refusal or the reasoning behind one.
