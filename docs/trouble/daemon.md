# The daemon

`satld` either refuses to start with an actionable message, or it starts and tells you what it could not do.
There is very little in between: every host prerequisite it cannot honour is a warning in the startup banner, not a silent degradation.
So the first move for anything on this page is always the same — read the banner.

```sh
sudo grep -a 'starting satld' /var/log/messages | tail -1
```

If that returns nothing, do not conclude the daemon never started:
[read the log properly](reading-the-log.md) first — a binary-looking log file
and an hourly rotation both produce exactly that silence.

## `Cannot connect to the SatL daemon at unix:///var/run/satl.sock. Is satld running?` { #socket-unreachable }

**Symptom**

```console
$ satl ps
Cannot connect to the SatL daemon at unix:///var/run/satl.sock. Is satld running?
```

**Check**

```sh
service satld status
sudo grep -a satld /var/log/messages | tail -40
ls -l /var/run/satl.sock
```

**Reading**

| What you see | Meaning |
| --- | --- |
| `satld is not running` | it is stopped, or it exited at startup — the log's last lines say which |
| `satld is running as pid N`, no socket file | it is up but did not reach the point of binding: look for a preflight failure below |
| `satld is running as pid N`, socket present, still refused | a permission problem — see [the next entry](#socket-permission) |
| the log ends on `storage preflight failed` | [ZFS](#zfs-missing) |
| the log ends on a config error | [an unknown or unparsable key](#unknown-config-key) |

**Fix.**
Whatever the log's last line names.
`satld` never exits without one.

??? note "Why this happens"

    The API socket is bound late in startup, after the ZFS preflight, the host probes and the node runtime are built.
    Anything fatal earlier means the socket file never appears, and the client's only visible symptom is a refused connection — which reads identically to "the service is stopped".
    A stale socket file from a previous run is removed at bind time; a non-socket file at that path is refused rather than deleted.

## `Permission denied` on the socket for a non-root user { #socket-permission }

**Symptom.**
`satl` works under `sudo` and fails without it.

**Check**

```sh
ls -l /var/run/satl.sock
id -Gn
```

**Reading.**
The socket is `srw-rw----`, mode `0660`, owned by the user and group `satld` runs as — root, so `root:wheel` on a stock FreeBSD host.
Only members of that group can talk to it.

**Fix.**
Add the operator to `wheel`, or use `sudo`.

!!! warning "`socket_group` does not currently change this"

    `satld.toml`'s `socket_group` key is parsed and printed in the startup banner, but the socket's ownership is not changed to match it: the mode is set to `0660` and the group stays the daemon's own.
    Setting `socket_group = "operators"` therefore has no effect on who can reach the API.
    The default value, `wheel`, happens to describe reality on a stock host.
    A dedicated group belongs with packaging, which SatL does not have yet — see [What SatL does not do](../reference/out-of-scope.md).

## `storage preflight failed` { #zfs-missing }

**Symptom**

```
ERROR satld: storage preflight failed
  error=ZFS root dataset 'zroot/satl' does not exist; create it with:
  zfs create -o mountpoint=/var/db/satl zroot/satl
```

or

```
dataset 'zroot/satl' has no usable mountpoint (mountpoint=legacy, from
`/sbin/zfs get -H -o value mountpoint zroot/satl`); set one with:
zfs set mountpoint=<path> zroot/satl
```

**Check**

```sh
zfs list -o name,mountpoint zroot/satl
grep -a zfs_root /usr/local/etc/satl/satld.toml
```

**Reading.**
ZFS is not one storage driver among several in SatL — it is the storage model, and the daemon refuses to start without its root dataset.
The two messages distinguish the two ways that can be wrong: the dataset is absent, or it exists with `mountpoint=none`/`legacy` and so has no path to serve from.

**Fix.**
Run the command the message prints.
It is complete and correct:

```sh
zfs create -o mountpoint=/var/db/satl zroot/satl
service satld start
```

A pool other than `zroot` is fine — set `zfs_root` in [`satld.toml`](../reference/satld-toml.md) to match, and keep `state_dir` equal to the dataset's mountpoint.
They are allowed to differ, and the daemon warns when they do (`zfs root dataset mountpoint differs from configured state_dir`), because nothing good comes of state living somewhere other than the dataset that holds it.

??? note "Why this happens"

    Image layers are datasets, applying a layer is a snapshot plus a clone, and a container's writable layer is a clone of the image's top snapshot.
    None of that has a fallback implementation, so starting on non-ZFS storage would mean starting a daemon that cannot run a single container.
    `satld` creates the children it needs (`raft`, `images`, `layers`, `containers`, `volumes`) on first start; only the root has to exist.

## `satld` will not start after an edit to `satld.toml` { #unknown-config-key }

**Symptom.**
The service was running, you edited the configuration, and now it exits immediately with a parse error naming a key.

**Check**

```sh
sudo satld --config /usr/local/etc/satl/satld.toml --log-target stdout
```

Running it in the foreground puts the error on your terminal instead of in the
log.

**Reading.**
**Unknown keys are rejected, not ignored.**
A typo — `pf_module` for `pf_mode`, a key that belongs to a newer version, a key copied from a Docker config — stops the daemon rather than being silently dropped.

**Fix.**
Correct the key against [`satld.toml`](../reference/satld-toml.md), which lists every key the daemon accepts.
That page is checked against the daemon's own configuration struct on every build of this site, in both directions.

!!! note "The shipped sample is not the whole list"

    `satld.toml.sample` documents 11 of the 13 keys; `cert_validity` and `overlay_blackhole` are absent from it.
    The [reference page](../reference/satld-toml.md) is the complete list.

## The daemon started, and the banner is full of warnings { #degraded }

**Symptom.**
`satld` is running, `satl version` answers, and yet something does not work: containers have no network, `--memory` does nothing, `linux/*` images will not schedule.

**Check.**
Read the startup warnings in order:

```sh
sudo grep -a -E 'NOT ENFORCED|NO OUTBOUND|linuxulator|devfs ruleset|egress' \
    /var/log/messages | tail -20
```

**Reading**

| Warning | What is degraded |
| --- | --- |
| `kern.racct.enable=0: rctl(8) rules cannot be installed, so --memory and --cpus are ACCEPTED BUT NOT ENFORCED. Add kern.racct.enable=1 to /boot/loader.conf and reboot to enable resource limits.` | resource limits are accepted by the API and enforced by nothing — see [containers](containers.md#limits-not-enforced) |
| `net.inet.ip.forwarding=0: containers will have NO OUTBOUND connectivity (published ports still answer, which makes this easy to misdiagnose).` | container egress — see [node-local networking](network-local.md#no-egress) |
| `no default route on this host: containers will have NO OUTBOUND connectivity because no NAT rule can be generated. Set egress_if in satld.toml if this node reaches other networks through a specific interface.` | container egress, same symptom, different cause |
| `linuxulator not available; only freebsd/* images can run (kldload linux)` | `linux/*` images are refused at task creation — see [containers](containers.md#linux-image-rejected) |
| `could not install the SatL devfs ruleset; jails will fail to mount /dev (satld must run as root)` | **every** container: no jail can mount `/dev` |
| `cert_validity is below one hour: node certificates will expire within minutes. This is a TESTING knob…` | this node is running a testing configuration on what may be a real cluster |

**Fix.**
Each message carries its own.
Two need a reboot or a foreground window rather than a config change:

```sh
# resource limits: a boot-time tunable, not a runtime sysctl
echo 'kern.racct.enable=1' | tee -a /boot/loader.conf   # sysrc(8) rejects dotted names;
                                                        # `>>` under doas/sudo opens the file as you
shutdown -r now

# IP forwarding: both, so it survives the next boot
sysrc gateway_enable=YES
sysctl net.inet.ip.forwarding=1
```

Do **not** set `rctl_enable="YES"` in `rc.conf`: that loads static rules from
`/etc/rctl.conf`, while SatL adds and removes its own rules per container.

??? note "Why these warn instead of refusing to start"

    Each of them describes a host that is still perfectly capable of running *something*.
    A node whose containers only talk to each other needs no egress; a node that runs only FreeBSD images needs no linuxulator; a node with no resource limits in any service spec loses nothing to racct being off.
    Refusing to start would turn a partial capability into an outage.
    What the daemon will not do is accept the flag and stay quiet about it — the reason is recorded in the task's status message as well as in the banner.

    The devfs one is the odd entry: it is an `ERROR`, not a warning, and it is
    almost always "satld is not running as root".

## A worker refuses to start after its state was moved { #worker-no-managers }

**Symptom**

```
this node holds a worker certificate but no manager list at
/var/db/satl/managers.json: it cannot find its cluster. Re-join it
(`satl swarm join`) or remove /var/db/satl/certs to start over as a fresh
single-node cluster.
```

**Check**

```sh
ls -l /var/db/satl/managers.json /var/db/satl/certs
```

**Reading.**
A worker holds no replicated store, so the only record it has of where its cluster lives is the manager list its session last reported, persisted at `<state_dir>/managers.json` and refreshed automatically.
Without it the node knows it is a worker and does not know whom to talk to.

**Fix.**
Either of the two the message names, and they mean different things:

```sh
# rejoin the existing cluster
satl swarm join --token <fresh worker token> <manager>:2377

# or: forget the cluster entirely and come up as a fresh single-node cluster
rm -r /var/db/satl/certs
service satld restart
```

The second discards this node's cluster identity.
Its containers' tasks belong to the old cluster and will be reaped.

## `satld` was killed and its containers kept running { #strays }

**Symptom.**
After a crash or a `kill -9`, jails are still running and `satl ps` disagrees with `jls`.

**Check**

```sh
jls -N
sudo grep -a -E 'adopt|reattached|datasets_destroyed' /var/log/messages | tail -20
```

**Reading.**
This is expected, in both directions.
Shutting `satld` down does not stop containers — a daemon restart is not an outage for the workloads.
On the way back up, the startup reconciliation pass adopts every jail it can match to a task it still owns, re-arms the exit watch, republishes the node's `rdr` rules, and destroys the jails, epairs and datasets that belong to nothing.

**Fix.**
Nothing, usually — wait for the startup pass and re-read `satl ps`.
If containers of tasks the cluster has since rescheduled are still alive minutes later, that is a real defect: collect what [Getting help](getting-help.md) asks for.

??? note "Why this happens"

    An interrupted VNET jail teardown can leak epair interfaces, and a container dataset can outlive its container by a minute for reasons that have nothing to do with the daemon ([containers](containers.md#dataset-busy)).
    The reconciliation pass is level-triggered for exactly that reason: it compares what is on the host against what the store and the local task database claim, rather than replaying what happened while it was away.
    Nothing has to be remembered, so nothing can be lost.
