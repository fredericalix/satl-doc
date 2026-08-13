# TLS, joins and certificates

Every internal connection in SatL — Raft, the dispatcher, the control API, the
NodeCA — is mutual TLS against the cluster's own root. Joins are pinned to that
root by the join token. So the failures on this page are all the same shape:
something presents a certificate the other end will not accept, and the symptom
is a connection that never establishes.

The one command that answers "what is this node *actually* presenting", as
opposed to what is on its disk:

```sh
openssl s_client -connect <node>:2377 </dev/null 2>/dev/null |
    openssl x509 -noout -subject -dates
```

## `root CA bundle does not match the join token` { #token-digest }

**Symptom**

```
root CA bundle does not match the join token: token pins digest <a>, the 1234
byte bundle received hashes to <b>. Refusing to trust it (a man-in-the-middle
may have replaced or appended a root certificate). Check that the join token was
copied from this cluster; if its root CA was rotated since (satl ca rotate),
every older token is void - fetch a fresh one with 'satl swarm join-token' on a
manager
```

**Check.** On a manager:

```sh
satl swarm join-token worker            # or: manager
satl ca                                 # the root(s) this cluster currently trusts
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the token you used differs from the one just printed | the token is stale — almost always a root CA rotation since it was issued |
| `satl ca` prints **two** certificates | a rotation is **in progress**; tokens rotate at its start *and* at its completion |
| the token matches and the join still fails | you are talking to a different cluster than you think, or something is intercepting the bootstrap connection |

**Fix.** Re-read the token on a manager and join with it. Nothing has to be
reset on the joining node for this error alone.

??? note "Why the digest is pinned, and why a rotation voids old tokens"

    The first contact a joiner makes is over the **unauthenticated** bootstrap
    listener on `2378` — it has no certificate yet, so it cannot use the mTLS
    port. What makes that safe is that the token carries a digest of the whole
    trust bundle: the joiner downloads the bundle, hashes it, and refuses to
    proceed unless it matches. A man in the middle can replace or append a root
    certificate and the digest catches it.

    Because the digest pins the *whole* bundle, and the bundle passes through
    three states during a root rotation (old → old + new → new), **tokens are
    regenerated twice per rotation**: at the start and at the completion. Docker
    regenerates only at completion. So a token read before `satl ca rotate` is
    void the moment the rotation starts, not when it finishes.

    The token format is `SATL-1-<digest>-<secret>`. Tooling that pattern-matches
    Docker's `SWMTKN` will not recognise it.

## `malformed join token: …` { #malformed-token }

**Symptom** — one of

```
malformed join token: expected 4 dash-separated fields (SATL-1-<digest>-<secret>), found 3
malformed join token: prefix is "SWMTKN", expected "SATL"
malformed join token: secret field is 24 characters, expected exactly 25
malformed join token: digest field contains characters outside base36 [0-9a-z]
unsupported join token version "2": this build of satl speaks version 1; the token was issued by a newer cluster
```

**Reading.** The token was truncated, wrapped by a terminal, copied from Docker,
or issued by a newer version of SatL. None of these ever reached the network.

**Fix.** Re-copy it. `satl swarm join-token worker` prints a ready-to-paste
`satl swarm join …` invitation — use that rather than reassembling the command
by hand.

!!! warning "A join token is a credential"

    It appears in shell history and in process listings if you pass it in an
    argv. SatL's own cluster harness feeds it on stdin for exactly that reason.

## `refused an internal TLS connection` on a manager { #refused-tls }

**Symptom**, in a manager's log:

```
WARN refused an internal TLS connection: the peer's certificate does not verify
     against this cluster's trust anchors. If that node was offline across a root
     CA rotation ('satl ca rotate'), its certificate chains to a dropped root and
     it must rejoin: 'satl swarm leave --force' there, then 'satl swarm join'
     with a fresh token …
```

**Check**

```sh
satl ca                                       # how many roots does the cluster trust?
openssl s_client -connect <the refused node>:2377 </dev/null 2>/dev/null |
    openssl x509 -noout -subject -dates -issuer
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the peer's issuer is a root `satl ca` no longer prints | it slept through a root CA rotation |
| the peer's certificate names a different cluster id | it was issued by another cluster's CA (`node <id> presented a certificate for cluster <x>, but this is cluster <y>`) |
| the peer's certificate is expired | see [the next entry](#expired-certs) |

**Fix.** The message contains the whole recovery, and it is the whole recovery:

```sh
# on the returning node
satl swarm leave --force
satl swarm join --token <fresh token> <manager>:2377
```

It comes back as a **new node id**. Its containers were long since rescheduled
elsewhere.

## Everything fails at once, some time after nothing changed { #expired-certs }

**Symptom.** The cluster coasts along fine — reads work, `satl node ls` says
`Ready` everywhere — and then, all at once, every session re-establishment fails
and keeps failing:

```
WARN satl_dispatcher::agent: agent session ended error=dispatcher rpc Session
     failed: … "invalid peer certificate: certificate expired: verification time
     1786516761 (UNIX), but certificate is not valid after 1786516687 (74 seconds
     ago)" … InvalidCertificate(ExpiredContext …)
```

```
ERROR openraft::replication: RPCError err=Unreachable node: … certificate expired
```

and every write is refused with
`this cluster has no raft leader right now`.

**Check**

```sh
# what the node PRESENTS
openssl s_client -connect <node>:2377 </dev/null 2>/dev/null |
    openssl x509 -noout -subject -dates
# what the renewal loop SAYS it did
sudo grep -a -E 'certificate renewed|issued node certificate|renewal failed' \
    /var/log/messages | tail -20
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the presented `not_after` is in the past, and the log shows **no** recent renewal | renewal is failing — grep for `certificate renewal failed; will retry` and read its reason (CA material missing from the store, disk full) |
| the presented `not_after` is in the past while the log is **still logging successful renewals** | the process is presenting a stale certificate: the disk is fresh and the live TLS configuration is not. **The fix is a daemon restart** |
| `satl node ls` still shows every node `Ready` with the old `Leader` | expected in this failure mode. It reads the last replicated store state, which can no longer change — do not trust it here |

**Fix.** Restart the daemon on the affected node if it is presenting something
other than what is on its disk. Otherwise fix what the renewal error names; the
certificate stays valid for a long while after the renewal window opens (20–45
days at production validity), so a few failed attempts are a warning, not an
incident.

!!! note "The treacherous part is that nothing breaks at expiry"

    Established connections never re-check certificates, so an expired identity
    costs nothing until the first reconnect — a network blip, a daemon restart
    on a peer, an idle connection cycling. Then everything fails at once, and it
    looks like a network event rather than a certificate that expired quietly
    twenty minutes earlier.

??? note "How renewal is supposed to work"

    Every node's certificate is renewed automatically at a random point in
    50–80 % of its validity — 90 days by default, so roughly a 50–70 day event —
    re-issued from the cluster root held in the Raft store, written to
    `<state_dir>/certs`, and **swapped into the live TLS configuration in the
    same breath**. No restart, ever: listeners and outbound channels resolve
    their certificate per handshake, so the very next connection presents the
    new one. Role changes ride the same mechanism, since the role *is* the
    certificate's OU.

    One line per renewal, and silence in between is the healthy state:

    ```
    INFO satld::identity: node certificate renewed and live TLS configuration swapped
         node_id=2et9… role="satl-manager" not_after=… server_config_swapped=true
         client_config_swapped=true
    ```

    Two things are expected and are not bugs: established connections keep their
    old identity until they reconnect, and the on-disk and presented `not_after`
    match only after that swap line — between the disk write and the swap there
    is no observable window.

## `node … has been removed from the cluster` { #removed-member }

**Symptom** — one of

```
node 2cd3… has been removed from the cluster: its certificate is blacklisted
until it expires. Re-join the node with a fresh join token to get a new identity
```

```
raft member 7 was removed from this cluster: its raft ID is blacklisted and can
never be re-admitted. Wipe its raft directory and re-join with a fresh join token
```

**Reading.** Someone ran `satl node rm` for this node. A removed node's
certificate and Raft identity are barred deliberately, so it cannot silently
rejoin the membership it was removed from.

**Fix.** Exactly what the message says, on the removed node:

```sh
satl swarm leave --force
satl swarm join --token <fresh token> <manager>:2377
```

It returns with a new node id.

## A root CA rotation does not finish { #rotation-stuck }

**Symptom.** `satl ca rotate` does not converge; `satl ca` keeps printing two
certificates and `GET /swarm` reports `RootRotationInProgress: true`.

**Check**

```sh
satl node ls                                 # is a node Down?
sudo grep -a -E 'ca_rotation|marked for re-issue|trust bundle changed|certificate signed' \
    /var/log/messages | tail -20
```

Expect, across the cluster:

```
leader:  root CA rotation: marked nodes for certificate re-issue  marked=3 converged=0 total=3
nodes:   cluster trust bundle changed; persisted and swapped live
         certificate marked for re-issue (root CA rotation); renewing now
leader:  root CA rotation completed: old root dropped, new root is the sole trust anchor
```

**Reading.** The rotation **waits for every node object** the store still lists,
deliberately: a node that has not been re-issued must not be cut off by dropping
the old root. So a node that is down holds the rotation open.

| Outcome | Meaning |
| --- | --- |
| a node is `Down` and will come back | just wait. It reconnects with its old certificate (still trusted), receives the transitional bundle and the re-issue mark over its session, and the rotation finishes |
| a node is `Down` and will never come back | it is the blocker |
| a second `satl ca rotate` is refused | correct: one rotation at a time, and the refusal carries the way out |

**Fix.** For a node that will never return:

```sh
satl node rm --force <node>
```

The reconciler stops waiting on the next tick.

!!! warning "Do not try to shortcut a stuck rotation on disk"

    Every fact the rotation acts on lives in the Raft store, and the reconciler
    re-asserts it. Editing certificates under `<state_dir>/certs` accomplishes
    nothing. The two operator levers are `satl node rm --force` and rejoining a
    node that missed the rotation.

    And note the trap on the other side: **a node that stays down through the
    whole rotation cannot reconnect afterwards** — its certificate chains to a
    root nobody trusts any more, and it shows up as
    [`refused an internal TLS connection`](#refused-tls).

## A join is refused because the node already has state { #join-refused-state }

**Symptom**

```console
$ satl swarm join --token <token> manager1:2377
Error response from daemon: this node cannot join a cluster: it runs 2
service(s). Remove them first, or reinstall the node; joining discards this
node's cluster state.
```

The reason varies: `it runs N service(s)`, `it holds N task(s)`,
`it is a manager of a N-node cluster`, `it holds N secret(s)` — and on a worker,
`it runs N task(s) of its current cluster`.

**Reading.** Every fresh SatL node self-initialises a single-node cluster, so
"this node is already a cluster" is the normal state of a node you have never
touched and is *not* what this refusal is about. The check is narrower: it
refuses only when the node holds **state a join would destroy**. The default
cluster object and the node's own node object do not count — they are what a
self-initialised node always has.

| Node | May join if |
| --- | --- |
| a manager | its store holds nothing but itself: no services, no tasks, no other nodes, no secrets |
| a worker | it runs no tasks of its current cluster |

Two neighbouring refusals are worth recognising, because they read similarly and
mean something else:

- `This node is already part of a swarm. Use "docker swarm leave" to leave this
  swarm and try again.` — that is **`swarm init` on a worker**, Docker's own
  wording. On a manager, `init` stays an idempotent success.
- `this node is one of 3 managers: removing it would need a quorum-safe
  membership change. Demote it from another manager first (\`satl node update
  --role worker\`), or pass force to leave anyway.` — that is `swarm leave` on a
  manager of a multi-member Raft group. A worker leaves without `--force`,
  exactly as Docker's does.

**Fix.** Remove what the message names, or `satl swarm leave --force` and then
join. To be certain the node is starting from nothing, stop the daemon and
destroy its state dataset:

```sh
service satld stop
zfs destroy -r zroot/satl && zfs create -o mountpoint=/var/db/satl zroot/satl
service satld start
```

!!! danger "That destroys the node's identity, certificates and Raft log"

    Including the `dek` file that encrypts the Raft log and snapshots at rest.
    On a multi-manager cluster the node can re-sync from peers after rejoining;
    a single-node cluster's state is gone. Do this only on a node you intend to
    re-join as new.
