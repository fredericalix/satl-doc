# SatL

SatL is a cluster-first container engine for FreeBSD: OCI containers as jails
through [ocijail](https://github.com/dfr/ocijail), with swarm-style
orchestration built in — embedded Raft, a scheduler, desired-state
reconciliation, a VXLAN overlay and mTLS everywhere. The CLI (`satl`) and the
REST API served by the daemon (`satld`) are Docker-compatible.

!!! info "Coming"

    This site is being written. What exists today is the machinery: the
    [CLI reference](reference/cli/index.md) is generated from the binaries
    themselves and checked against the SatL source on every build.

## Where to look

| | |
| --- | --- |
| [About](about/index.md) | What SatL is and is not |
| [Getting started](start/index.md) | Install it, run something |
| [Configuration](config/index.md) | `satld.toml` |
| [Using SatL](use/index.md) | Containers, services, networks |
| [Clustering](cluster/index.md) | Managers, workers, the overlay |
| [Images](images/index.md) | Registries and the ZFS layer store |
| [Troubleshooting](trouble/index.md) | When it does not work |
| [Reference](reference/index.md) | Every command, every config key |
