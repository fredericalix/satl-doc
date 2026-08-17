# Reading the log

`satld` runs under `daemon(8)` and hands every event to the local `syslogd`, so **`/var/log/messages` is the only place its output lands**.
The CLI shows you the operator-facing summary; the log shows which command failed, with what argv, and what the kernel said about it.
Almost every page in this chapter tells you to read it, and almost every wrong diagnosis in SatL's own history started with reading it badly.

Two traps come first, and they come first for one reason: **both of them make a diagnostic return nothing at all.**
Not an error — nothing.
Which is indistinguishable from "the daemon never logged that", and that is the single most expensive way to be wrong during an incident.

## Trap 1: `grep` decides your log is binary { #grep-a }

**Symptom.**
A grep that should match returns no output and exit status 1:

```console
# grep 'task_id=1kql' /var/log/messages
# echo $?
1
```

**Check.**

```sh
file /var/log/messages
```

**Reading.**

| Output | Meaning |
| --- | --- |
| `/var/log/messages: ASCII text` | the file is clean; your pattern really did not match |
| anything else (`data`, `ISO-8859 text`, `UTF-8 Unicode text`, …) | **`grep` is treating the whole file as binary and printing nothing** |

One single byte outside ASCII, written by *any* program on the host — not necessarily `satld` — is enough.
GNU-style `grep` on a file it judges binary prints no matching lines and exits 1, exactly as if the pattern were absent.

**Fix.**
Always pass `-a`:

```sh
grep -a 'task_id=1kql' /var/log/messages
```

Every command in this chapter uses `grep -a`.
Copy them with the flag; a habit is cheaper than remembering why.

??? note "Why this happens"

    Everything `satld` writes reaches the file through `syslogd`, which is not 8-bit clean: it rewrites bytes in the `0x80`–`0x9f` range as the literal text `M-^X`.
    A UTF-8 punctuation character is two or three bytes, usually including one in that range, so it arrives mangled and unrecoverable — an em dash logged as `—` lands as `M-^@M-^T` (measured on FreeBSD 15.1 with `logger`, read back with `od -c`).

    That is why SatL keeps every operator-facing message ASCII-only: identifiers, interface names, addresses and state names are all greppable exactly as printed.
    It is also why a stray non-ASCII byte from some *other* daemon can silently disarm your grep against SatL's lines.

## Trap 2: the line you want was rotated an hour ago { #rotation }

**Symptom.**
"Did this node ever start?
Did it ever gain leadership?
Did that task ever get created?"
— and the log says nothing.

**Check.**
Look at what else is in the directory:

```sh
ls -l /var/log/messages*
```

**Reading.**
`newsyslog` runs from `/etc/crontab` **at minute 0 of every hour** and, with FreeBSD's stock `/etc/newsyslog.conf`, rotates `/var/log/messages` once it passes 1000 KB, keeping five bzip2-compressed archives.
On a node running `satld`, that is roughly hourly.
**A daemon 80 minutes old already has its `starting satld` line in `messages.0.bz2`** — measured on the SatL test cluster, where the first version of a leader-detection helper consequently found no leader on any of three nodes.

**Fix.**
Any "did this ever happen" question must read the archives oldest-first *and then* the live file.
One line, copy-pasteable:

```sh
{ for f in $(ls -tr /var/log/messages.*.bz2 2>/dev/null); do bzcat "$f"; done
  cat /var/log/messages; } 2>/dev/null | grep -a satld | grep -a 'starting satld'
```

`bzgrep -a <pattern> /var/log/messages.*.bz2` works for a single-shot search,
but it does not interleave with the live file and it does not preserve order
across archives — use the loop above whenever *when* matters.

!!! tip "Old runs come along, and that is fine"

    Reading the archives pulls in lines from before the incident.
    That is harmless as long as you pin your search to an identity — a task ID, a node ID, a service name.
    SatL IDs are 25 characters of base36 and a task is one-shot, so a hit on a task ID can only be about that task.

## One event is one line { #merged-lines }

The rc.d service starts the daemon with `--log-target syslog`, and that flag is
a correctness requirement, not a preference: with it, `satld` hands each event to
`syslogd` as its own datagram, so **one event is one line**.

Two shapes are therefore bugs to report, never something to work around:

- **two timestamps on one line, or two `{` under `--log-format json`.**
  Events written microseconds apart by two of the daemon's threads have been joined.
- **`M-^` escape sequences in a line.**
  Some message escaped the ASCII-only rule.
  (Characters *above* `0x9f`, such as `§` or `é`, do survive intact in the file. If you see those rendered as `M-BM-'`, that is your pager, not the log: `cat -v` and non-UTF-8 tools display intact bytes that way.)

??? note "Why this happens"

    Without `--log-target syslog` the log travels the way any supervised program's output does: the daemon writes lines to a pipe and `daemon(8) -S` forwards them.
    `daemon(8)` reads that pipe in *chunks* and passes a whole chunk to `syslog(3)` as one message; `syslogd` then rewrites the newlines inside it as spaces.

    Measured on FreeBSD 15.1 against this daemon's own log: **281 of 7252 lines (3.9 %) carried more than one event**, up to eleven, and under `--log-format json` about 3 % of lines were two objects on one line — not JSON, so a consumer doing one `json.loads` per line fails on them.
    A synthetic burst of 400 lines through `daemon -S` was worse: 138 lines carrying 174 records, up to 19 per line, and **more than half the records lost outright**, because merging inflates each datagram until it overruns `syslogd`'s 16 KiB receive buffer.
    The same 400 lines through `logger(1)`, which calls `syslog(3)` once per line, arrived complete.

    `-S` is still passed to `daemon(8)` on purpose: the log no longer travels that way, but a panic written to stderr does, and it should still be captured.
    A multi-line panic backtrace can still merge — that path is the fallback, not the log.

    If `syslogd` is unreachable, the daemon prints one `satld: cannot write the log to syslog …` note to stderr and falls back to writing lines there.
    That fallback can merge lines; it never drops them.

## Grep by identity, not by time { #span-chain }

Between the level and the module, every line carries the spans it happened
inside, outermost first:

```
INFO agent.session{node_id=1r5f...}:task_step{step="prepare" task_id=1kql... service=pub}:
     jail_create{jail_id=1kql... platform=Freebsd}: satl_runtime::runtime: jail created
```

That chain is what makes the log greppable by identity rather than
chronologically: the `node_id` on the outer span applies to everything nested
under it, so

```sh
grep -a 'task_id=1kql' /var/log/messages
```

returns one task's whole life, in the context of the session and the node that ran it.
The identifiers worth pinning a search to are `task_id`, `service_id`, `node_id`, `session_id`, `jail_id`, and `from`/`to` on state transitions.

Two shapes of the chain itself are bugs rather than noise:

- **a background loop's span nested under anything.**
  `dispatcher.sweep`, `dispatcher.status` and `agent.session` are the roots of their own tasks and always appear first.
  A line reading `dispatcher.sweep{...}:agent.session{...}:` means one loop's span leaked onto a runtime thread and was picked up by an unrelated task, so its events are attributed to a subsystem that did not produce them — and to another node's `manager_id` at that.
- **the same span twice in one chain**, or a chain that keeps growing across restarts.
  Same cause.

## Turning the volume up { #rust-log }

| Want | Do |
| --- | --- |
| more detail from one subsystem | `satld_env="RUST_LOG=satld=debug,satl_cluster=debug"` in `rc.conf`, then restart |
| machine-readable output | `satld_flags="--log-format json"` in `rc.conf` |
| watch it live in a terminal | stop the service and run `satld --log-format json \| jq` in the foreground |

Every event carries one syslog priority, `daemon.notice`, whatever its tracing level — so `RUST_LOG=satld=debug` output still lands in `/var/log/messages` with the stock `syslog.conf`.
Mapping tracing levels onto syslog severities would move `INFO` and `DEBUG` out of that file, which is why it is not done.

In the foreground the default is `--log-target stdout`, and colour is emitted only when stdout is really a terminal.
**ANSI escapes in a log file are a bug.**

See [`satld`](../reference/cli/satld.md) for the flags and
[`satld.toml`](../reference/satld-toml.md) for the file.

## The three commands worth memorising

```sh
sudo grep -a satld /var/log/messages | tail -200      # what the daemon has been saying
sudo grep -ac ERROR /var/log/messages                 # is it complaining at all?
sudo grep -a '<some id>' /var/log/messages            # one object's whole life
```

For how logging is configured — targets, formats, levels, and what a line is made of — see [Logging](../config/logging.md).
This page is only about not being misled by what you read back.
