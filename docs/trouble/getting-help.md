# Before you report a problem

A SatL bug report is worth roughly what its log excerpt is worth.
Everything below is about collecting an excerpt that answers the next three questions without another round trip.

Two rules to apply before you paste anything:

- **`grep -a`, and read the rotated files too.**
  A report saying "the daemon logged nothing" is nearly always a report where [one of the two traps](reading-the-log.md) fired.
- **Pin the excerpt to an identity, not to a time window.**
  A task ID, a service ID, a node ID.
  SatL IDs are 25 characters of base36 and a task is one-shot, so a grep on one can only be about the thing you mean.

## What to collect

### 1. What is running

```sh
satl version
uname -a
freebsd-version -kru
sudo grep -a 'starting satld' /var/log/messages | tail -1
```

The startup banner is one line and carries the effective configuration: version, git commit, config file and whether it was actually read, socket path, state dir, ZFS root, node name, `pf_mode`, listen and advertise addresses, and the certificate validity in force.
It is the single most useful line in a report, and it is the one most likely to have been rotated away — read [the archives](reading-the-log.md#rotation) if it is not in the live file.

### 2. What the daemon said

Rotation-aware, ASCII-safe, pinned to an identity:

```sh
{ for f in $(ls -tr /var/log/messages.*.bz2 2>/dev/null); do bzcat "$f"; done
  cat /var/log/messages; } 2>/dev/null | grep -a satld > /tmp/satld-full.log

grep -a '<task or node or service id>' /tmp/satld-full.log > /tmp/satld-excerpt.log
```

Include the excerpt **and** the count of errors in the full file, which tells a
reader whether the daemon is unhappy in general or only about your object:

```sh
grep -ac ERROR /tmp/satld-full.log
grep -a ERROR  /tmp/satld-full.log | tail -40
```

If the daemon is reproducibly wrong, re-run with more detail.
`RUST_LOG` wins over the configured level, and JSON is easier to hand to someone else:

```sh
sysrc satld_env="RUST_LOG=satld=debug,satl_cluster=debug,satl_dispatcher=debug"
sysrc satld_flags="--log-format json"
service satld restart
```

### 3. What the host looks like

The four facts that explain most "it works on my machine" divergence:

```sh
sysctl kern.racct.enable net.inet.ip.forwarding
zfs list -o name,mountpoint,used | grep -i satl
kldstat -m if_vxlan ; kldstat -m linux
pfctl -s info | head -3 ; pfctl -a 'satl/*' -s all
```

Plus, when networking is involved at all:

```sh
ifconfig -a
netstat -rn | grep default
netstat -s -p ip | grep -i fragment          # host stack: outer fragmentation
```

### 4. What the cluster thinks

On a manager:

```sh
satl node ls
satl service ls
satl service ps <the service>
satl service inspect <the service>
satl network ls
```

!!! warning "Say which node each command was run on"

    A worker answers Docker's `This node is not a swarm manager.` for most of these, and a manager reports **its own** view of node-local things — health, a network's gateway.
    "Which node" is part of the data.

    And do not report the `MANAGER STATUS` column as evidence of who leads: it is written when the cluster forms and never refreshed ([why](cluster.md#stale-manager-status)).
    Read leadership from the log.

### 5. The smallest thing that reproduces it

The most valuable line in a report is the command that shows the problem.
If the problem needs a cluster, say how many nodes and which roles; if it needs an image, name one that is publicly pullable, or describe the entrypoint and the platform of yours.

## What not to paste

| Never | Why |
| --- | --- |
| a **join token** | it is a credential. Redact everything after `SATL-1-` |
| the contents of `<state_dir>/raft/dek` | it is the key that encrypts the Raft log and snapshots at rest — treat it like a private key |
| private keys under `<state_dir>/certs` | the certificates themselves are fine; the keys are not |
| secret or config **payloads** | names are fine and appear in the log by design; payloads never do |

!!! danger "A secret payload in `/var/log/messages` is itself the bug"

    Secret *names* appear in the daemon log (`materialized dependency payload`, `secret assigned/withdrawn`).
    A payload byte sequence must never appear there.
    If you find one, that is the report — say so plainly, and do not attach the log to a public tracker.

## Things that are expected and are not bugs

Save yourself the round trip.
All of these are documented behaviour:

| You see | Read |
| --- | --- |
| a container dataset still present a minute after `satl rm` | [containers](containers.md#dataset-busy) |
| a published port refusing on `localhost` of the publishing node | [node-local networking](network-local.md#localhost) |
| a node with no replica of a service not answering its published port | [node-local networking](network-local.md#published-port-silent) |
| `satl service ls` reading `8/6` while a node is down | [the cluster](cluster.md#replica-count) |
| a dead node still shown as `Leader` | [the cluster](cluster.md#stale-manager-status) |
| a returned node staying empty after a drain | [the cluster](cluster.md#no-rebalance) |
| `start` refused on a stopped container | [containers](containers.md#start-refused) |
| `--privileged` and friends rejected with a 400 | [containers](containers.md#rejected-options) |
| `PreviousSpec` empty after an automatic rollback | [the cluster](cluster.md#update-paused) |

## Things that are always bugs

Report these on sight, with the line that shows them:

- **two timestamps, or two `{`, on one log line** — one event is one line by
  construction ([why](reading-the-log.md#merged-lines));
- **`M-^` escape sequences** in a log line — a message escaped the ASCII-only
  rule;
- **ANSI colour escapes** in a log *file* — colour is emitted only to a terminal;
- **a background loop's span nested under another span**, or the same span twice
  in one chain ([why](reading-the-log.md#span-chain));
- **a secret payload** anywhere in the log;
- **a task id in a `published ports converged` line after that node's own
  `published ports removed` for it** ([why](network-local.md#round-robin)).

## Where to send it

Issues go to the SatL repository:
<https://github.com/fredericalix/satl/issues>. A fix to this documentation goes
to <https://github.com/fredericalix/satl-doc> — every page has an edit link in
its top-right corner, which is the shortest path for a wrong sentence.

SatL is at 0.1.0-beta and the gaps people actually walk into are the ones worth
closing first, so a report of the shape described above is genuinely useful — and
a report saying "this worked, on this hardware, with this workload" is worth more
than you would think.
