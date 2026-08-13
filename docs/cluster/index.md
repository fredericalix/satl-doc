# Clustering

Managers, workers, Raft, join tokens and the overlay network.

!!! info "Coming"

    The narrative part of this section — bringing up managers and workers, join
    tokens, promotion and demotion, the overlay — has not been written yet. The
    scaffolding, the generated [CLI reference](../reference/cli/index.md) and the
    build checks are in place; the prose is next.

One page of it does exist, and it is the one to read before you commit to a
topology: **[Backup and restore](backup-restore.md)**. It covers what cluster
state actually is, how to copy it, how to put it back, and the arithmetic that
decides how many managers to run — three, and a backup of two of them.
