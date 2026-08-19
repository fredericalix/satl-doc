# Configuration

`satld` reads one file, `/usr/local/etc/satl/satld.toml`, and every key in it is optional.
A host with no configuration file at all runs entirely on defaults, and for a single-node install that is very nearly the right thing to do — the [minimal file](#the-file-a-first-install-needs) below is two keys long, and one of them is commented out.

This section is about the decisions.
What each key is *for*, what it costs to get wrong, and which of them you will never touch.
The exact types, defaults and validation rules are in the [`satld.toml` reference](../reference/satld-toml.md), which is checked against the daemon's own `struct ConfigFile` on every build — in both directions, so a key the daemon accepts cannot go undocumented and a key documented here cannot fail to exist.

## Three things worth knowing before you edit it

**A typo is a startup failure, not a silent no-op.**
Unknown keys are rejected, so `pf_mode` misspelled as `pfmode` stops the daemon with the offending name rather than leaving you to wonder why published ports do nothing.
A malformed file is fatal for the same reason.
This is the single most useful property of the file and it is the opposite of how most daemons behave.

**No environment variable configures any of it.**
There is no `SATL_*` override for any key: the file, and only the file.
`RUST_LOG` changes the log level and `DOCKER_HOST` points the *client* somewhere, but neither is a configuration key, and nothing you export into `satld`'s environment changes what it reads.

**Exactly one key has a command-line override**, `metrics_addr` / `--metrics-addr`, and the flag wins.
Every other setting is changed by editing the file and restarting the daemon — including the cluster addresses, which is why `satl swarm init --advertise-addr` on an already-initialised node is an error that points you back here rather than a way to change them.

## The file a first install needs { #the-file-a-first-install-needs }

--8<-- "satld-toml-minimal.md"

`pf_mode` is the one that matters.
The built-in default is `check`, which generates SatL's `pf` rules and syntax-checks them without ever loading one — so a published port is allocated, reported by `satl ps`, and redirected nowhere.
That default is deliberate (a daemon that seizes the host firewall on first start would be worse), and it is also the reason the [install page](../start/install.md) treats writing this file as a step you do not skip.

## The pages

- **[`satld.toml`](satld-toml.md)** — the file itself, grouped the way you
  actually meet it: storage first because it is the one that refuses to start,
  then the API socket, then `pf`, then networking, then the cluster addresses,
  then the keys you will probably never set.
- **[The rc.d service](service.md)** — the four `rc.conf` knobs, the command
  line the script builds from them, and why removing `--log-target syslog`
  corrupts the log rather than merely relocating it.
- **[Logs](logging.md)** — where lines go, how to turn the volume up, how to
  read one, and the two traps (`grep -a`, and more than one event per line).
- **[Node state on disk](state.md)** — the five datasets, what lives in the
  state directory, the `dek` file that seals the Raft log, and autolock.

Cluster-wide settings are a different thing entirely and are not in this file: they live on the cluster object inside Raft, and they are set with `satl` commands rather than edited.
`satld.toml` configures *this node*.
