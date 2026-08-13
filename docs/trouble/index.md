# Troubleshooting

!!! danger "Read this before trusting a diagnostic that returned nothing"

    Two properties of `/var/log/messages` on FreeBSD make a correct command
    print **nothing at all** and exit non-zero, which is indistinguishable from
    "the daemon never logged that": `grep` silently treats the whole file as
    binary if any program on the host wrote one non-ASCII byte, and `newsyslog`
    rotates the file about once an hour, so a daemon 80 minutes old already has
    its startup line in `messages.0.bz2`.

    **[Reading the log](reading-the-log.md) first.** Every other page here
    assumes it.

### The CLI said…

| Symptom | |
| --- | --- |
| `Cannot connect to the SatL daemon at unix:///var/run/satl.sock. Is satld running?` | [the daemon](daemon.md#socket-unreachable) |
| `Permission denied` on the socket for a non-root user | [the daemon](daemon.md#socket-permission) |
| `storage preflight failed` / `ZFS root dataset … does not exist` | [the daemon](daemon.md#zfs-missing) |
| `satld` exits after an edit to `satld.toml` | [the daemon](daemon.md#unknown-config-key) |
| `This node is not a swarm manager.` | [the cluster](cluster.md#not-a-swarm-manager) |
| `cannot …: this cluster has no raft leader right now` | [the cluster](cluster.md#no-raft-leader) |
| `container … has already run and cannot be started again` | [containers](containers.md#start-refused) |
| `HostConfig.Privileged is not supported by SatL: …` | [containers](containers.md#rejected-options) |
| `satl service ps <name>` prints an empty table and exits 0 | [the cluster](cluster.md#empty-service-ps) |
| `root CA bundle does not match the join token` | [TLS and joins](tls.md#token-digest) |
| `malformed join token: …` | [TLS and joins](tls.md#malformed-token) |
| `This node is already part of a swarm.` | [TLS and joins](tls.md#join-refused-state) |
| `node … has been removed from the cluster` | [TLS and joins](tls.md#removed-member) |

### The container…

| Symptom | |
| --- | --- |
| never leaves `Pending`; `ERROR` says `no suitable node (…)` | [containers](containers.md#no-suitable-node) |
| is `REJECTED` naming the linuxulator or an init system | [containers](containers.md#linux-image-rejected) |
| exits immediately with empty logs | [containers](containers.md#silent-exit) |
| ignores `--memory` / `--cpus` | [containers](containers.md#limits-not-enforced) |
| shows `(health: starting)` forever, then fails | [containers](containers.md#unhealthy-task) |
| leaves its ZFS dataset behind after `satl rm` | [containers](containers.md#dataset-busy) |
| cannot pull its image | [containers](containers.md#pull-fails) |
| resolves no names at all | [node-local networking](network-local.md#no-dns) |

### The network on one node…

| Symptom | |
| --- | --- |
| the container reaches nothing outbound, but its published port answers | [node-local networking](network-local.md#no-egress) |
| a published port refuses connections | [node-local networking](network-local.md#published-port-silent) |
| `curl localhost:<port>` fails on the node that publishes it | [node-local networking](network-local.md#localhost) |
| one node answers correctly, then wrongly, in bursts | [node-local networking](network-local.md#round-robin) |
| `epair`s or bridges are left behind after a failure | [node-local networking](network-local.md#leaked-interfaces) |

### The network between nodes…

| Symptom | |
| --- | --- |
| a task cannot reach **any** remote task on the network | [the overlay](overlay.md#no-remote-reach) |
| **one pair** of tasks fails and everything else works | [the overlay](overlay.md#one-pair) |
| everything works, throughput is poor, packet counts are doubled | [the overlay](overlay.md#fragmentation) |
| large transfers stall while pings answer | [the overlay](overlay.md#fragment-drop) |
| a task loses the network some time after a configuration change | [the overlay](overlay.md#stale-arp) |
| a service name does not resolve, or resolves to the wrong service | [the overlay](overlay.md#dns) |
| the first overlay network on a fresh host fails to program | [the overlay](overlay.md#kldload) |

### The cluster…

| Symptom | |
| --- | --- |
| `satl node ls` names a dead node `Leader` | [the cluster](cluster.md#stale-manager-status) |
| a node reads `Down` | [the cluster](cluster.md#node-down) |
| `satl service ls` says `8/6` | [the cluster](cluster.md#replica-count) |
| a rolling update stopped halfway and says `paused` | [the cluster](cluster.md#update-paused) |
| a crash-looping task stopped being replaced | [the cluster](cluster.md#restart-budget-spent) |
| a drained node came back and stayed empty | [the cluster](cluster.md#no-rebalance) |
| editing a node label moved running containers | [the cluster](cluster.md#label-moves-tasks) |
| a worker refuses to start after its state was moved | [the daemon](daemon.md#worker-no-managers) |
| `satld` was killed and its containers kept running | [the daemon](daemon.md#strays) |
| everything fails at once, some time after nothing changed | [TLS and joins](tls.md#expired-certs) |
| `refused an internal TLS connection` on a manager | [TLS and joins](tls.md#refused-tls) |
| a root CA rotation does not finish | [TLS and joins](tls.md#rotation-stuck) |

### The log…

| Symptom | |
| --- | --- |
| a `grep` that should match prints nothing and exits 1 | [reading the log](reading-the-log.md#grep-a) |
| the line you want is not there — "did this ever happen?" | [reading the log](reading-the-log.md#rotation) |
| two timestamps, or two `{`, on one line | [reading the log](reading-the-log.md#merged-lines) |
| `M-^` sequences in a line | [reading the log](reading-the-log.md#merged-lines) |
| a background loop's span nested under another span | [reading the log](reading-the-log.md#span-chain) |
| the daemon started but the banner is full of warnings | [the daemon](daemon.md#degraded) |

---

Not a failure, just a difference from Docker? See
[Differences from Docker](../docker-differences.md). Ready to report something?
[What to collect first](getting-help.md).
