# Node-local networking

Everything on this page is about one node's own plumbing: the `satl0` bridge, the per-task `epair`, the `satl/*` pf anchors and the NAT that gets a container to the outside world.
Cross-node traffic is [the overlay](overlay.md).

One asymmetry explains most of the confusion here, so it is worth having in mind before you start: **inbound and outbound break independently.**
Inbound redirection is a pf `rdr` rule and works with no routing at all; outbound needs the host to route the bridge subnet to the egress interface *and* a NAT rule to translate it.
A host missing either of those has published ports that answer perfectly while the container cannot reach a registry or a DNS server, which reads as "the container is broken" rather than "the host is not configured".

## The container reaches nothing outbound { #no-egress }

**Symptom.**
Inside the container, every outbound connection times out or fails to resolve, while the same container answers on its published port from another machine.

**Check**

```sh
sysctl net.inet.ip.forwarding
netstat -rn | grep default
sudo pfctl -a satl/nat -s nat
sudo grep -a -E 'NO OUTBOUND|egress interface' /var/log/messages | tail -5
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `net.inet.ip.forwarding: 0` | the host does not route, so packets from the bridge subnet never reach the egress interface and the NAT rule matches nothing useful |
| no default route, and the daemon logged `no default route on this host: containers will have NO OUTBOUND connectivity because no NAT rule can be generated.` | there is no interface to NAT out of, so **no `nat` rule was generated at all** |
| `pfctl` prints `nat on <iface> inet from 10.88.0.0/24 to any -> (<iface>)` | the rule exists; the problem is elsewhere (forwarding, or the host's own firewall policy) |
| `pfctl: … does not exist` | the anchor is empty; either `pf_mode` is not `enforce`, or pf is not enabled |

**Fix**

```sh
sysrc gateway_enable=YES              # persistent
sysctl net.inet.ip.forwarding=1       # immediate
```

On a multi-homed node, for instance one where containers must leave through a
private interface rather than the public one; pin the interface instead of
letting the daemon take it from the default route:

```toml
# /usr/local/etc/satl/satld.toml
egress_if = "vtnet1"
```

??? note "Why the parenthesised interface in the rule"

    The generated rule is `nat on <egress> inet from <subnet> to any -> (<egress>)`.
    The parentheses make pf re-evaluate the interface's address rather than baking in whatever it held at load time, so the rule survives a DHCP renewal or an interface that only comes up later.

    `satld` regenerates its whole anchor on every change; there are no
    incremental edits, and it refuses, in code, to load into any anchor outside
    `satl`/`satl/*`.

## A published port refuses connections { #published-port-silent }

**Symptom.**
`satl ps` or `satl service ls` shows the port, and nothing answers on it from another host.

**Check**

```sh
grep -a pf_mode /usr/local/etc/satl/satld.toml
pfctl -s info | head -2
sudo pfctl -a satl/rdr -s nat
sudo grep -a 'published ports converged' /var/log/messages | tail -5
satl service ps <service>                       # which nodes run a task?
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `pf_mode` absent or `"check"` | **the default.** Ports are allocated and displayed, and no redirect is installed. Nothing will ever answer |
| `Status: Disabled` from `pfctl -s info` | pf is not enabled on the host; `enforce` has nothing to load into |
| the anchor holds a rule, and only *some* nodes answer | correct behaviour; see the note below |
| the anchor holds no rule on a node that *is* running a task | a defect; grep the log for that task id and collect [what Getting help asks for](getting-help.md) |
| nothing in the log about published ports | also normal: the daemon logs one line per **change**, so a steady node is silent |

**Fix**

```toml
# /usr/local/etc/satl/satld.toml
pf_mode = "enforce"
```

plus pf enabled on the host, with the three anchor lines declared in
`/etc/pf.conf`: see [Ports and firewall](../reference/ports.md) for the minimal
file.

!!! warning "A node that runs no task of the service does not answer"

    SatL's ingress publishing is not Docker's routing mesh.
    The port is allocated cluster-wide and then redirected **on each node that runs a task of the service, to that node's own task**.
    A node running no replica refuses the connection, and that is the correct behaviour, not a degraded one.

    Two operator consequences: put a load balancer in front of the swarm with a **health check on the port**, and never assume every node serves it.
    A service scaled to fewer replicas than there are nodes is not reachable everywhere.

??? note "The anchor repairs itself, and that is deliberate"

    An ingress port is never *announced* to a node: it is allocated centrally and arrives as a field of a task object in the replicated store, not as an event.
    A node that published only when it saw something happen would therefore never publish an ingress port at all.

    So `satld` recomputes the whole `satl/rdr` anchor from the tasks running on that node every five seconds, and reloads pf only when the ruleset text changes.
    An anchor flushed by hand comes back within a minute; one lost across a daemon restart comes back with the daemon; a failed `pfctl` load is retried by the next pass, and the daemon never records a ruleset it failed to load.

## `curl localhost:<port>` fails on the node that publishes it { #localhost }

**Symptom.**
The port answers from another machine and refuses on the publishing host itself.

**Check.**
From a different machine:

```sh
curl -sv http://<node public address>:<port>/
```

**Reading.**
If it answers from elsewhere, nothing is wrong. pf applies `rdr` to packets **entering** an interface, never to locally generated traffic, so a connection from the host to its own address is not redirected.
Docker on Linux papers over this with an iptables `OUTPUT` rule; there is no equivalent here and there never was.

**Fix.**
Test from another machine, or reach the container by its own bridge address (`satl inspect <container>` reports it).

## One node answers correctly, then wrongly, in bursts { #round-robin }

**Symptom.**
Requests to one node fail roughly every other attempt, in bursts of about five seconds, then recover.

**Check**

```sh
sudo pfctl -a satl/rdr -s nat
sudo grep -a -E 'published ports (removed|converged)' /var/log/messages
```

**Reading.**
A node running two tasks of one service holds **one** rule with a round-robin address pool:

```
rdr pass inet proto tcp from any to any port 18080 -> { 10.88.0.2, 10.88.0.3 } port 80 round-robin
```

so one dead address in a two-address pool produces exactly the every-other-request signature.
The tell in the log is a task id appearing in a `published ports converged` line **after** that same node's `published ports removed` for it.

**Fix.**
There is nothing to configure.
If you see that signature, a republished task id, it is a defect worth reporting with the log lines.
The known cause of it (a manager-side pass republishing a task the store had not yet caught up on) is fixed, and a redirect is now created only for a task whose desired state is still below `SHUTDOWN`.

??? note "Why one rule and not one per task"

    pf evaluates translation rules in order and **the first match decides** (`pf.conf(5)`).
    Emitting one rule per task would leave every task but the first looking published and never receiving a connection.
    `round-robin` is pf's own answer, and `pfctl` normalises a bare address list to it anyway, so SatL spells it explicitly.

    A container that has just started can still lose a request or two: without a `Healthcheck`, `RUNNING` means "the jail started", not "the server has finished binding".
    Adding a healthcheck to the service is what closes that window.

## The container resolves no names { #no-dns }

**Symptom.**
Addresses work, names do not, inside the container, from the very first command.

**Check**

```sh
satl exec <container> cat /etc/resolv.conf
```

and from the node:

```sh
sockstat -4l | grep ':53'
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `/etc/resolv.conf` missing or empty | nothing was written: on a node-local network the file is a copy of the host's, so check the host's own `/etc/resolv.conf` first |
| one `nameserver` line per attached network, each an address on this node | correct; a name that still does not resolve is a [service discovery](overlay.md#dns) question |
| a `nameserver` line pointing at another node's address | the container is talking to a responder that will forward its queries upstream instead of answering them |

**Fix.**
For a node-local container, fix the host's resolver configuration; `resolv.conf` is *written* into the container's writable layer at prepare time rather than bind-mounted, so it is per-container and never touches the shared image layers.
Do not edit it inside a running container and expect it to survive: the container is one-shot.

## Interfaces or jails left behind after a failure { #leaked-interfaces }

**Symptom.**
`ifconfig` shows `epair`s or bridges with SatL descriptions that belong to no running container.

**Check**

```sh
ifconfig -g satl                                    # SatL's own group
ifconfig -a | grep -B4 'description: satl:'         # ownership markers
jls -N
```

**Reading.**
The description is the ownership marker and the only reliable one; an interface group does not survive a `vnet` move or the jail's destruction, while the description survives both.
The forms are:

| Description | What it is |
| --- | --- |
| `satl:network:<net>` | a node-local bridge, **not** a leftover |
| `satl:<task>` | both ends of a node-local task's epair |
| `satl:overlay:<net>` | an overlay network's bridge on this node |
| `satl:overlay:<net>:<task>` | both ends of an overlay task's epair |
| `satl:vxlan:<net>` | the network's VTEP |

**Fix.**
Restart `satld` and let the startup sweep do it.
The sweep enumerates SatL's own group plus the `epair`, `bridge` and `vxlan` driver groups, then classifies each interface by its description; anything it can name completely and that belongs to no live task is destroyed.

!!! note "Anything it cannot name completely is left alone"

    An unrecognised `satl:…` description classifies as *unowned*, and unowned is never destroyed.
    That is what keeps an older daemon from sweeping a marker form a newer one introduced, and it is why `<group>` is the configurable `network_name`: **two daemons on one host must use different names**, or each one's reconciliation destroys the other's interfaces.
