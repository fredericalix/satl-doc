# SatL

SatL is a cluster-first container engine for FreeBSD.
It runs OCI containers as jails through [ocijail](https://github.com/dfr/ocijail), stores image layers as ZFS datasets, wires containers with `if_bridge`, `epair` and `pf`, and carries the orchestration inside the daemon rather than beside it: an embedded Raft store, a scheduler, desired-state reconciliation, a VXLAN overlay with service discovery and optional per-network encryption, and mTLS between nodes with a certificate authority of its own.
The surface is Docker's — the `satl` CLI speaks the verbs you already know, and `satld` serves the Docker Engine REST API on `/var/run/satl.sock`, so the `docker` CLI works against it unchanged.

Which means the first hour is mostly familiar.
`satl run`, `satl ps`, `satl logs`, a compose file — they do what you expect.
What is different sits underneath: one daemon to install, nothing beside it to operate, and a single machine that is already a cluster of one, so adding the second one is a join rather than a migration.

## Where to start

<div class="grid cards" markdown>

-   **Evaluating it**

    ---

    What SatL actually is, what FreeBSD gives it and takes away from it, and an
    honest list of what is built and what is not.

    [What SatL is](about/what-satl-is.md) ·
    [Why FreeBSD](about/why-freebsd.md) ·
    [Status](about/status.md)

-   **A first install**

    ---

    The checklist before you type anything, then a host prepared and a daemon
    running, then one container serving traffic — with the traps named where
    you will hit them.

    [Requirements](start/requirements.md) ·
    [Install](start/install.md) ·
    [First container](start/first-container.md)

-   **A three-node cluster**

    ---

    Managers, workers, join tokens, the overlay network, published ports and
    what quorum costs you.

    [Clustering](cluster/index.md)

</div>

## Status: early, and real

SatL is at **0.1.0-beta**, its first public release, under the [BSD-2-Clause licence](about/status.md#licensing) — the same terms as FreeBSD itself.
There is a FreeBSD package to install:

```sh
fetch https://satl.cc/download/satl-freebsd.pkg
pkg add ./satl-freebsd.pkg
```

"Beta" here is a statement about the edges, not the middle.
The feature set runs real workloads — the [Node.js + MariaDB tutorial](start/app-node-mariadb.md) on this site goes end to end on a three-node cluster — and everything documented here has been *run*, on FreeBSD 15.1 amd64.
Nothing on this site is documented from intent.

What that leaves, plainly: no independent security audit, no compatibility promise between pre-1.0 versions and no upgrade path across them, FreeBSD 15.1 on amd64 only, and IPv4 only.
Cluster state has a [measured backup and restore procedure](cluster/backup-restore.md), but no `satl` verb performs it, and a cluster that permanently loses quorum cannot be repaired from inside.
What is missing is listed, by name, on the [status page](about/status.md).

If you try it, the most useful thing you can send back is a log excerpt and the
command that produced it — [what makes a report
useful](trouble/getting-help.md).
