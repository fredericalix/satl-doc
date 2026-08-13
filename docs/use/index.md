# Using SatL

Containers, services, images, networks, volumes and secrets, day to day.

- **[Containers and services](containers-and-services.md)** — the model
  everything else follows from: every container is a task of a service, and what
  that changes about `start`, `rm` and `ps`.
- **[Images](images.md)** — pulling, platform selection, registries and
  authentication, and where the bytes land as ZFS datasets.
- **[Networks](networks.md)** — the node bridge, overlays, addresses and
  container DNS.
- **[Publishing ports](publishing-ports.md)** — host mode, ingress mode, and why
  `curl localhost` on the publishing host never works.
- **[Volumes, binds and tmpfs](storage.md)** — what persists, what does not, and
  what a volume costs.
- **[Secrets and configs](secrets-and-configs.md)** — where a payload goes, what
  it may be, and why rotation is by replacement.
- **[Resource limits](resource-limits.md)** — `--memory` and `--cpus` as
  `rctl(8)` rules, and the boot-time tunable they need.
- **[Healthchecks](healthchecks.md)** — Docker's semantics, plus the two things
  health *does* here that it does not there.
- **[Rolling updates](rolling-updates.md)** — the twelve policy flags, the rule
  that decides what yours did, and automatic rollback.
- **[Compose files](compose.md)** — `satl compose up` with stack semantics, the
  supported subset, and what it refuses rather than ignores.
- **[Reclaiming space](reclaiming-space.md)** — `satl system prune`, which is
  manual and node-local, and why a layer sometimes survives the first run.
