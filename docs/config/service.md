# The rc.d service

`make install` puts an rc.d script at `/usr/local/etc/rc.d/satld`.
It is the supported way to run the daemon: `satld` does not daemonize itself, and the script is where the two things it needs — detaching, and a log that is not corrupted — are arranged.

```sh
sysrc satld_enable=YES
service satld start
service satld status
```

## The four rc.conf knobs

| Variable | Default | What it does |
| --- | --- | --- |
| `satld_enable` | `"NO"` | the rcvar. Nothing starts until this is `YES` |
| `satld_config` | `/usr/local/etc/satl/satld.toml` | passed to `satld` as `--config`. A missing file is fine — the daemon runs on defaults |
| `satld_flags` | `""` | extra `satld` flags, e.g. `--log-format json` |
| `satld_env` | `""` | environment for the daemon, e.g. `RUST_LOG=satld=debug` |

```sh
sysrc satld_flags="--log-format json"
sysrc satld_env="RUST_LOG=satld=debug,satl_cluster=debug"
service satld restart
```

`satld_env` is handled by `rc.subr(8)`, which exports it before starting the command, so it is the way to reach anything the daemon reads from the environment — in practice `RUST_LOG`.
See [Logs](logging.md) for what the filter accepts.

??? note "Why `satld_flags` is cleared inside the script"

    The script builds the whole command line itself, because the daemon runs under `daemon(8)` and `satld`'s flags have to land on `satld` rather than on `daemon`.
    `${satld_flags}` is interpolated into `command_args` and then set to the empty string, since `run_rc_command` would otherwise *also* insert it between `${command}` and `${command_args}` — where `daemon(8)` would receive it and reject it.

    So: adding a flag to `satld_flags` works exactly as you expect.
    Editing the script by hand is where the ordering matters.

## The command line the service builds

```sh
/usr/sbin/daemon -f -S -T satld -p /var/run/satld.pid \
    /usr/local/sbin/satld --config ${satld_config} --log-target syslog ${satld_flags}
```

`daemon(8)` detaches (`-f`), writes the child's pidfile (`-p`), and forwards
whatever the child prints to stderr into syslog (`-S`) under the tag `satld`
(`-T`).

## Do not remove `--log-target syslog`

That flag is a correctness requirement, not a preference.
If you edit `command_args` for any reason, keep it.

With the flag, `satld` hands each log event to `syslogd` itself, as its own datagram.
**One event, one line.**
Without it, the daemon's output travels the way any supervised program's output does — written to a pipe, forwarded by `daemon(8) -S` — and that path merges events: `daemon(8)` reads the pipe in chunks and hands a whole chunk to `syslog(3)` as a single message, and `syslogd` then rewrites the newlines inside it as *spaces*.
Two events written microseconds apart by two of the daemon's threads arrive joined onto one line.

!!! danger "This is measured, not theoretical"

    On FreeBSD 15.1, against this daemon's own log:

    - **281 of 7252 lines (3.9%) carried more than one event**, up to eleven of
      them on a single line;
    - under `--log-format json`, about **3% of lines were two JSON objects on one
      line** — which is not JSON, so a consumer doing `json.loads` per line fails
      on them;
    - a synthetic burst of 400 lines through `daemon -S` was far worse: 138
      lines carrying 174 records, up to 19 records on one line, and **more than
      half the records lost outright** — merging inflates each datagram until it
      overruns `syslogd`'s 16 KiB receive buffer.

    The same 400 lines through `logger(1)`, which calls `syslog(3)` once per line, arrived complete.
    `daemon(8)` has no flag that asks for per-line forwarding.

    The operational tell: **two timestamps on one line, or two `{`, is this bug.**
    The daemon's own events are one per line by construction.

`-S` stays on the `daemon(8)` command line anyway, and that is not an inconsistency.
`satld`'s log no longer travels that way, but a panic message written to stderr does, and a panic should still reach the log.
That path is the fallback, not the log.

## What a restart does — and does not — touch

```sh
service satld restart
```

!!! success "A restart is not an outage for your containers"

    Running jails are **deliberately left alone**.
    `satld` does not stop containers on the way down and does not recreate them on the way up: it re-adopts them.

Concretely, on the way back up the daemon reads its local task database, matches what it finds against the jails and datasets actually on the host, and takes ownership of what is still alive.
In the log:

```
INFO apply_snapshot{changes=4}:init_from_disk{live=4}: satl_agent::worker:
     resuming task from the local db task_id=2qw3gxb4uklpaowonekzukj02
     state=running decision=Reattach { pid: 20684 }
INFO apply_snapshot{changes=4}:init_from_disk{live=4}: satl_agent::controller:
     re-armed exit watch on adopted container
     task_id=2qw3gxb4uklpaowonekzukj02 pid=20684
```

`decision=Reattach` is a container that kept running across the restart, with the same pid it had before; the daemon re-arms its exit watch so it still notices when that container dies.
`decision=Resume` is a task that had already finished and is simply carried forward.

The same pass is what cleans up: jails, container datasets and network interfaces that no task claims any more are destroyed, and published ports are re-derived and re-loaded into pf.
One line summarises it:

```
INFO run{node_id=...}: satld::reconcile: startup reconciliation complete
     jails_destroyed=0 datasets_destroyed=0 epairs_destroyed=0
     overlay_epairs_destroyed=0 overlay_bridges_destroyed=0 vteps_destroyed=0
     ports_republished=1
```

Non-zero `*_destroyed` counts after a clean restart are worth a look — they mean
the previous shutdown left something behind — but they are exactly what you want
to see after a crash or a `kill -9`.

What a restart *does* interrupt is the daemon-side work: the REST API is unavailable for the moment it takes to come back, the node's dispatcher session to its managers is re-established, and if this node was the Raft leader an election happens.
None of that stops a container that is already running.

!!! warning "A restart is how a configuration change takes effect"

    `satld` reads [`satld.toml`](satld-toml.md) once, at startup.
    There is no reload signal.
    Since a restart leaves containers running, this is a much cheaper operation than it would be on an engine that had to stop them — which is the point of doing adoption properly.

## Stopping

`service satld stop` stops the daemon and, again, leaves running jails alone.
That is the right behaviour for a restart and it is worth being explicit about for a shutdown: containers on a host whose `satld` is stopped keep running until something else stops them, and will be re-adopted when the daemon comes back.
The script carries `KEYWORD: shutdown`, so a system shutdown stops the daemon in the right order relative to ZFS and the network.

To remove a workload, remove the service — see [Containers and
services](../use/containers-and-services.md) — rather than stopping the daemon.
