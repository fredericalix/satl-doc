# SatL

SatL is a cluster-first container engine for FreeBSD. It runs OCI containers as
jails through [ocijail](https://github.com/dfr/ocijail), stores image layers as
ZFS datasets, wires containers with `if_bridge`, `epair` and `pf`, and carries
the orchestration inside the daemon rather than beside it: an embedded Raft
store, a scheduler, desired-state reconciliation, a VXLAN overlay with service
discovery, and mTLS between nodes with a certificate authority of its own. The
surface is Docker's — the `satl` CLI speaks the verbs you already know, and
`satld` serves the Docker Engine REST API on `/var/run/satl.sock`, so the
`docker` CLI works against it unchanged.

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

## Status

SatL is **pre-1.0 and pre-release**. There are no tagged releases, no FreeBSD
package, no upgrade path between versions and no tested backup/restore
procedure. The only way to install it is to build it from source on the machine
that will run it. Everything documented here has been run on FreeBSD 15.1
amd64; nothing here is documented from intent. What is missing is listed, by
name, on the [status page](about/status.md).
