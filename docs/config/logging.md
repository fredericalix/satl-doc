# Logs

`satld`'s log is not a supplement to its error messages — it is the only place a
diagnosis actually comes from. The CLI shows an operator-facing summary; the log
shows which `zfs`, `ifconfig`, `pfctl` or `ocijail` command ran, with its full
argument list, its exit status and its stderr. Whenever you exercise the daemon
for real, read the log.

## Where it goes

Under the rc.d service, `satld` runs with `--log-target syslog` and hands every
event to the local `syslogd` as its own datagram, tagged `satld`. With FreeBSD's
stock `/etc/syslog.conf` that lands in:

- `/var/log/messages`
- `/var/log/daemon.log`

```sh
sudo grep -a satld /var/log/messages | tail -50
```

!!! danger "Always `grep -a`"

    A single non-ASCII byte anywhere in `/var/log/messages` — written by any
    program on the host, not necessarily `satld` — makes `grep` treat the whole
    file as binary and print **nothing**, with exit status 1 and no explanation.
    That looks exactly like "the daemon logged nothing", which is the worst
    possible way to be misled while diagnosing.

    `grep -a` reads it as text regardless. `file /var/log/messages` reporting
    anything other than "ASCII text" is the tell.

Every event is emitted at one syslog priority, `daemon.notice`, regardless of
its own level. That is deliberate: mapping tracing levels onto syslog severities
would move `INFO` and `DEBUG` lines out of `/var/log/messages` under the stock
configuration, so turning on debug logging would make the output harder to find
rather than easier.

In the foreground the default target is stdout instead:

```sh
satld --config /usr/local/etc/satl/satld.toml            # text, colour if a terminal
satld --log-format json | jq                             # one JSON object per line
```

Colour is emitted only when stdout is really a terminal. **ANSI escape sequences
in a log file are a bug**, not a display setting.

??? note "If syslogd is unreachable"

    The daemon prints one `satld: cannot write the log to syslog …` note to
    stderr and falls back to writing lines there, where `daemon(8) -S` picks
    them up. That fallback can merge lines (see [The rc.d
    service](service.md#do-not-remove-log-target-syslog)); it never drops them.
    A saturated `syslogd` gets backpressure — the send is retried for up to two
    seconds — rather than having events dropped on the floor.

## Turning the volume up

The default level is `info`. Two ways to change it, and one of them wins:

```sh
# the flag
sysrc satld_flags="--log-level debug"

# the environment variable, which overrides the flag when set
sysrc satld_env="RUST_LOG=satld=debug,satl_cluster=debug"

service satld restart
```

`RUST_LOG` takes the usual `target=level` form, comma-separated, so you can turn
one subsystem up without drowning in the rest. The targets are the crate paths
you see in the log's module field: `satld`, `satl_cluster`, `satl_dispatcher`,
`satl_agent`, `satl_net`, `satl_overlay`, `satl_orchestrator`, `satl_sched`,
`satl_runtime`, `satl_storage`, `satl_image`, `satl_api`, `satl_ca`.

`--log-format json` switches to one JSON object per line, which is what to use
if anything downstream parses the log.

## Reading a line

A line has four parts after syslog's own prefix: the level, the span chain, the
module, and the message with its structured fields.

```
Aug 12 19:17:29 alpha satld[68947]: 2026-08-12T19:17:29.746393Z  INFO
  run{node_id=1oihjf6ers1k3v6ow4lxiy5bd}:publish_ports{task_id=2qw3gxb4uklp… ports=1}:
  satl_net::pf: loaded pf anchor anchor=satl/rdr
  rules=rdr pass inet proto tcp from any to any port 8080 -> 10.88.0.5 port 80
```

| Part | Here | What it tells you |
| --- | --- | --- |
| level | `INFO` | `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE` |
| span chain | `run{…}:publish_ports{…}:` | what was happening, outermost first |
| module | `satl_net::pf` | which subsystem said it — also the `RUST_LOG` target |
| message + fields | `loaded pf anchor anchor=… rules=…` | prose, then machine-readable fields |

The span chain is the parent chain: the outer span's fields apply to everything
nested under it. So the line above is telling you that inside the daemon's main
run loop, while publishing ports for one task, `satl-net` loaded the `satl/rdr`
anchor — and it prints the exact ruleset it loaded, which is the thing you would
otherwise have gone to `pfctl` for.

## Grep by identity, not by time

Reading the log chronologically is almost always the wrong approach: several
loops run concurrently, so a single subject's events are scattered. The span
chain exists precisely so you do not have to. Every identifier is ASCII and
appears exactly as printed, so grep for one:

```sh
sudo grep -a 'task_id=1kql' /var/log/messages    # one task's whole life
sudo grep -a 'node_id=1oihjf'  /var/log/messages # one node, everything under it
sudo grep -a 'service=web'     /var/log/messages # one service
sudo grep -a 'jail_id='        /var/log/messages # jail create/start/stop
sudo grep -a 'session_id='     /var/log/messages # one dispatcher session
```

Because the outer span's `node_id` applies to everything nested under it,
`grep -a 'task_id=1kql'` returns that task's whole life *in the context* of the
session and node that ran it — the prepare step, the jail creation, every state
transition, and the cleanup:

```
INFO agent.session{node_id=1r5f…}:task_step{step="prepare" task_id=1kql… service=pub}:
     jail_create{jail_id=1kql… platform=Freebsd}: satl_runtime::runtime: jail created
```

State transitions carry `from` and `to`, so the task state machine is greppable
end to end. Grep for words rather than symbols: SatL keeps operator-facing
messages ASCII-only, so every identifier a diagnosis needs is exactly what you
would type.

A few searches that answer a specific question:

```sh
# is it complaining at all?
sudo grep -ac ERROR /var/log/messages

# what the daemon decided about this host at startup
sudo grep -a 'starting satld' /var/log/messages | tail -1

# published ports: one line per change, silence is healthy
sudo grep -a 'published ports converged' /var/log/messages

# a container dataset waiting on a dying jail (see On-disk state)
sudo grep -a 'has not finished dying' /var/log/messages
```

## Two traps

Two shapes in the log mean something other than what they look like, and both
have cost people an afternoon: **`grep` silently printing nothing** on a file it
decided was binary, and **two events joined onto one line** by a log path that
was not meant to carry them.

They are covered, with what to check and what to do, in
[Reading the log](../trouble/reading-the-log.md).
