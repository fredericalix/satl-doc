# Defaults and constants

The values SatL uses when you do not choose one. Only the ones an operator can
actually observe are listed — internal tuning constants are not on this page.

Most of these are SwarmKit's own defaults, adopted deliberately so that a
service spec written for Docker Swarm behaves the same way here. Where SatL
differs, the row says so.

## Task and service behaviour

| | Default | Where it shows up |
| --- | --- | --- |
| Stop grace period | **10 s** | how long a container has after its stop signal before `SIGKILL`. It lives in the task spec and is immutable, which is why `docker stop -t` is ignored |
| Restart condition | **`any`** | a task that exits for any reason is replaced |
| Restart delay | **5 s** | the wait before a replacement is created. Paid in full for every eviction trigger **except a drain**, which forces it to zero |
| Restart max attempts | **unlimited** | per replica *and* per spec version. A service update starts a fresh budget |
| Task history retained per slot | **5** | what `satl service ps` can show you of a slot's past. Raised to `MaxAttempts + 1` when that is larger |

!!! note "Setting a non-default restart policy needs the API"

    `satl service create` carries `--restart-condition` but none of
    `--restart-delay`, `--restart-max-attempts` or `--restart-window`. A service
    that needs anything but the defaults above has to be created over the REST
    API. Durations on the wire are **nanoseconds**, as everywhere in the Docker
    API.

## Rolling updates

| | Default | Note |
| --- | --- | --- |
| Update parallelism | **1** | one slot at a time. `0` means "every slot at once" and must never be arrived at by omission — which is why naming one update flag fills the rest of that half from these defaults |
| Update monitor window | **5 s** | the failure-observation window. **SatL makes it part of each batch**, so a six-replica update takes at least 30 s at these defaults |
| Update failure action | **`pause`** | the rollout stops where it is; push a corrected spec to resume |
| Update order | **`stop-first`** | the old task is stopped before its replacement starts |
| Update max failure ratio | **0** | one failed task is enough to trip the failure action |
| Rollback policy | same six fields, same defaults | except `--rollback-failure-action`, which takes `pause`/`continue` only |
| Monitor window when `delay >= monitor` | **`delay + 1 s`** | so a long delay cannot make the window meaningless |
| Old-task stop wait before a `stop-first` promotion | **1 min** | how long the updater waits for the outgoing task to actually stop |

## Cluster liveness

| | Default | Note |
| --- | --- | --- |
| Dispatcher heartbeat | **5 s**, jittered ±500 ms | worker → manager |
| Session TTL | **3 × heartbeat** | so **a silent node reads `Down` after roughly 15 s** |
| Node `Down` → tasks `ORPHANED` | **24 h** | until then, a down node's tasks keep their last reported state — which is why `satl service ls` can read `8/6` |
| Node description refresh | **20 s** | how quickly a relabelled or re-described node is reflected |
| Agent session backoff | 100 ms → 8 s, jittered | reconnection after a lost session |
| Raft heartbeat / election / tick | 1 / 10 / 1 s | one election tick per second, election after ten missed |
| Snapshot interval | **10 000 writes** | when a `raft/snapshot` file first appears |

## Networking

| | Default | Note |
| --- | --- | --- |
| Node-local bridge pool | **`10.88.0.0/16`** | a `/24` is carved out per node-local network. Change `network_pool` if it collides with your underlay |
| Node-local network name | **`satl`** (bridge `satl0`) | also the interface group SatL sweeps at startup. **Two daemons on one host must use different names.** Max 14 characters |
| Overlay address pool / subnet size | **`10.100.0.0/14`** / **`/24`** | one subnet per overlay network |
| Overlay gateway | **`.1` is reserved and given to nobody** | each participating node gets its own gateway address from the subnet |
| VXLAN UDP port | **4789** | see [Ports and firewall](ports.md#vxlan) |
| Encrypted-overlay VTEP ports | **4790–4999**, one per encrypted network | only networks created with `--opt encrypted`; the datagrams there are ESP, not cleartext VXLAN — see [Ports and firewall](ports.md#encrypted-vxlan) |
| Overlay MTU | **underlay MTU − 50** | measured, never assumed. 1450 on a 1500 underlay; **underlay − 84** (1416) on an encrypted network, where ESP adds 34 bytes |
| Ingress dynamic port range | **30000–32767** | what a published port of `0` is assigned from. One cluster-wide owner per `(protocol, published port)`, sticky across updates |
| `pf_mode` | **`check`** | generate and syntax-check only — **published ports are not redirected until this is `enforce`** |

## Security

| | Default | Note |
| --- | --- | --- |
| Root CA validity | **20 years** | rotate with `satl ca rotate` when you need to, not on a schedule |
| Node certificate validity | **90 days** | `cert_validity` overrides it, and is a **testing knob**: values below one hour draw a loud startup warning and below one minute are refused |
| Renewal window | **50–80 % of validity**, at a random point | so a 90-day certificate renews as a roughly 50–70 day event, without a fleet-wide stampede |
| Clock-skew backdate | 1 h, capped at ⅛ of the validity | which is why even a five-minute test certificate renews before it expires |
| Removed node's certificate blacklist | until expiry, plus a week | a removed node cannot silently rejoin |
| Secret max size | **500 KiB** | enforced client-side first, then by the daemon |
| Config max size | **1000 KiB** | same |
| Secret file mode | **`0444`** | on the wire it is a Go `os.FileMode`, i.e. **decimal** — `292` |
| Secret mount | a per-task **tmpfs** under `/run/secrets` | never on the node's disk |

## Identifiers and paths

| | Default |
| --- | --- |
| Object ID format | **25 characters, base36** — nodes, services, tasks, networks, secrets, configs |
| Container `Id` in the Docker API | that same task ID, not a 64-hex string |
| API socket | `/var/run/satl.sock`, mode `0660` |
| Configuration file | `/usr/local/etc/satl/satld.toml` |
| State directory | `/var/db/satl` |
| ZFS root dataset | `zroot/satl` |
| Internal listener | `0.0.0.0:2377`, with the bootstrap listener on the next port up |

Every one of the last five is a key in [`satld.toml`](satld-toml.md).

## What has no default because it has no limit

Worth stating explicitly, because their absence surprises people:

- **nothing collects images or layers on a timer**, so disk use under
  `<zfs_root>/layers` and `<zfs_root>/images` grows until you run
  `satl system prune` — per node, since that is the scope it reclaims. See
  [Reclaiming space](../use/reclaiming-space.md);
- **there is no rebalancer**, so tasks moved off a node by a drain stay where
  they were re-placed;
- **there is no per-node endpoint limit on an overlay network** worth planning
  around — the static forwarding table is unbounded in practice. What *is*
  bounded is the kernel's debugging dump of that table, which stops at 81
  entries without saying so.
