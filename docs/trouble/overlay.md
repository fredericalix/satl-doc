# The overlay

Everything on this page was measured on FreeBSD 15.1, on a three-node cluster, against the kernel source of the same release.
Where a number appears, it is a number that was observed rather than computed.

Two properties of this platform shape every entry below, and both of them are
ways for the overlay to lie to you:

- **the exit status of a network configuration command is not evidence that anything happened.**
  `ifconfig` reports success, `UP` and `status: active` for a VXLAN interface the driver refused to initialise; `arp -s` prints `cannot locate` on stderr and exits 0.
  Read the result back; do not trust the exit code.
- **a wrong MTU does not break anything visibly.**
  `vxlan_encap4()` clears DF on the outer header, so an oversized frame is *fragmented*, not dropped.
  The overlay keeps working, every ping answers, every transfer completes byte-exact, while paying two packets per frame.
  This is the dangerous case, and the fragmentation counters are the only thing that reports it.

## Diagnostic order

When you do not yet know which entry you are in, work down this list.
It is ordered by how often each step is the answer, and the first step is the only one that distinguishes "our accounting is wrong" from "the fabric changed".

1. **DF ping sweep the underlay**, every node to every other.
2. Compare every overlay interface's MTU against that measurement − 50 (− 84
   on an encrypted network),
   **including the in-jail `epair` `b` ends**, which are the ones nothing
   propagates to.
3. Check the **outer fragmentation counters on both ends**
   (`netstat -s -p ip`, host stack).
4. Check `RUNNING` on each VXLAN interface, and read `/var/log/messages`.
5. Check `Oerrs` **and `Opkts`** on the VXLAN interface.
6. Only then look at the FDB and the in-jail ARP table.

## A task cannot reach *any* remote task on the network { #no-remote-reach }

**Symptom.**
Every peer on one overlay network is unreachable from one node.
Local tasks on the same network are fine.

**Check**

```sh
ifconfig <satl-vx-*> | head -1
ifconfig -g vxlan
sudo grep -a -E 'vxlan|destination address type|network identifier' /var/log/messages | tail -20
```

**Reading.**
The whole diagnosis is one flag in the first word.

| Flag word | Kernel line in `/var/log/messages` | Meaning |
| --- | --- | --- |
| `1008843<UP,BROADCAST,RUNNING,…>` | `link state changed to UP` | healthy |
| `1008803<UP,BROADCAST,…>`, **no `RUNNING`** | `cannot initialize interface: destination address type is not supported` | the VTEP has no usable remote address |
| `1008803<UP,BROADCAST,…>`, **no `RUNNING`** | `network identifier 4242 already exists in this socket` | that VNI is already in use on this node's VXLAN socket |

`ifconfig` exits 0 and prints `status: active` in **all three** cases.
The absence of `RUNNING` is the only signal the interface itself gives you; the reason is only in the kernel log.

**Fix.**
Both failing states are configuration, not damage: correct the network object (or the node's `overlay_blackhole`) and let the daemon recreate the interface.
A destroy/create cycle needs a full FDB re-push, which the daemon does; an interface *flap* does not, because static entries survive `down`/`up`.

??? note "Why the interface exists at all if it is broken"

    The duplicate-VNI check runs on `up`, not on `create`; the UDP socket does not exist until then.
    And a static FDB entry installs perfectly well on a dead interface: the FDB needs only the destination address family, not a working socket.
    So **FDB programming is not a health check**, and neither is a successful `create`.

    Several networks per node legitimately share one UDP socket on port 4789 with different VNIs, each keeping an independent FDB.
    (Encrypted networks are the exception: each binds its own port from 4790–4999; see [below](#encrypted).) The duplicate-VNI check exists to protect that sharing.

## One pair of tasks fails and everything else works { #one-pair }

**Symptom.**
Task A on node 1 and task B on node 3 cannot talk.
Every other pair on the same network is fine.
**One of the two nodes reports 100 % packet loss; the other sees nothing wrong.**

**Check.**
On **both** nodes:

```sh
sysctl -n net.link.vxlan.<unit>.ftable.count      # trustworthy size
sysctl -n net.link.vxlan.<unit>.ftable.dump       # the entries — read the trap below
```

To find `<unit>`; the sysctl tree is keyed by the clone unit, not by the
interface name, and nothing maps one to the other:

```sh
sysctl -N net.link.vxlan |
    sed -n 's/^net\.link\.vxlan\.\([0-9]*\)\.ftable\.count$/\1/p'
```

**Reading.**
**The FDB is per direction, and the node reporting total loss is usually the correctly configured one.**
Deleting node 1's entry for node 3's endpoint breaks the pair in *both* directions: node 3's echo requests still arrive (its own entry is fine), but node 1's *replies* are unicast to node 3's MAC, whose entry is the one that is missing.
So node 3 sees 100 % loss and node 1's tables are the broken ones.

**Diagnose from the sender of the replies.**

**Fix.**
The daemon reconciles the table from the store, so a missing entry is either a transient it will repair or a defect worth reporting.
What is exactly reversible by hand is nothing: re-adding an entry restores the pair with nothing else touched, but the reconciler owns the table.

!!! danger "Three counter traps, all measured"

    - **`ftable.dump` stops at 81 entries and the truncated output looks complete.**
      The kernel formats it into a fixed `PAGE_SIZE` buffer and backs out the partial line, so the output stays perfectly well-formed and carries no hint that anything is missing.
      Measured: 80 entries → 80 lines; 81 → 81; 82 → **81**; 2500 → **81**.
      An IPv6 remote widens the line and lowers the ceiling to about 51.
      **`ftable.count` is the trustworthy size**: compare the two before believing a dump.
    - **`ftable_nospace` can never move.**
      It counts learning failures on a code path SatL never reaches, because learning is off.
      A zero there is not evidence of a healthy table.
    - **`Oerrs == 0` proves nothing.**
      Non-zero means frames went to the blackhole default remote; something tried to reach an endpoint the control plane has not programmed.
      But with an on-link blackhole, `arpresolve()` returns `EWOULDBLOCK` for the first `net.link.ether.inet.maxtries` (default **5**) frames after the ARP entry is created, and those are counted in **`Opkts`** as successful transmits.
      Measured: 4 BUM frames on a fresh entry → `Opkts +4`, `Oerrs` **0**; the next 6 → `Opkts +1`, `Oerrs +5`; delete the ARP entry and the count starts over.
      A three-ping connectivity probe is entirely invisible.

    Prefer comparing the FDB against what the control plane says it programmed, and use `tcpdump -ni <underlay> "udp port 4789"` when you want to watch the frames themselves.
    On an encrypted network the frames are ESP, not UDP; see [below](#encrypted).

## Everything works, throughput is poor, packet counts are doubled { #fragmentation }

**This is the dangerous one.**
It passes every functional test.

**Symptom.**
The overlay works.
Every ping of every size answers.
Transfers complete byte-exact.
Throughput is disappointing and loss seems higher than the underlay's.

**Check**: on the **hosts**, both ends:

```sh
netstat -s -p ip | grep -i fragment
ifconfig <satl-vx-*> | grep -i mtu
ping -c 1 -D -s 1472 <peer underlay ip>     # must pass  (1472 + 28 = 1500)
ping -c 1 -D -s 1473 <peer underlay ip>     # must fail: "Message too long"
```

and from inside a jail on the overlay:

```sh
ping -c 2 -D -s 1422 <peer overlay ip>      # must pass  (1422 + 28 = 1450)
ping -c 1 -D -s 1423 <peer overlay ip>      # must fail
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| `fragments created` and `fragments received` at **0** on both hosts | correct. Overlay MTU = underlay − 50 |
| non-zero `fragments created` on the sender, `fragments received` on the receiver, at about **2 per datagram** | a forgotten −50. Every full-size frame is split in two and reassembled on the far side |
| the DF sweep says the underlay is not what you assumed | the fabric changed; recompute the overlay MTU from the measurement |

Measured on a 16 MiB transfer over a correct 1450 overlay: `out_frag +0 frags_created +0` on both nodes.
Over a 1500 overlay on the same 1500 underlay: sender `out_frag +11826 frags_created +23652`, receiver `frags_rcvd +23361`.

**Fix.**
Set the overlay MTU from a measurement, never from a guess.
SatL computes `underlay MTU − 50` and sets it explicitly; if your underlay is not 1500, measure it first with the DF sweep above.

!!! danger "Do not expect throughput to reveal this"

    Across runs, the reference link delivered **33–66 MB/s in *correct* configurations**, a wider spread than the difference between right and wrong in any single run.
    One run measured the broken configuration at half the correct one; the final run measured them within 10 %.
    What moves the number on a shared virtual switch is packet loss in the hypervisor (0.4–2 %), not encapsulation.

    **The fragmentation counters are the only reliable signal.**
    And nothing in the kernel warns: setting an MTU by hand latches `VXLAN_FLAG_USER_MTU` and the driver stops having an opinion.

??? note "Where the 50 bytes go, and where the MTU has to be set"

    14 Ethernet + 8 UDP + 8 VXLAN + 20 IPv4 = 50, from the driver's own header length computation.
    An IPv6 VTEP would cost 70, giving 1430.

    The driver's default *looks* right by coincidence: it computes `ETHERMTU - hdrlen`, and `ETHERMTU` is the constant 1500, not the underlay interface's MTU.
    On a jumbo underlay it would still say 1450.
    So the MTU is always set explicitly, and there are exactly two places to set it plus one ordering constraint:

    | Interface | Set by |
    | --- | --- |
    | the VXLAN interface | the bridge, or explicitly |
    | the **bridge** | explicitly, **after the first `addm`**; the first member added overwrites the bridge's MTU, and from then on the bridge propagates to every member |
    | the `epair` `a` end (a bridge member) | the bridge, and **only** the bridge: `SIOCSIFMTU` is `EOPNOTSUPP` on a member, even for the value it already holds |
    | the **in-jail `epair` `b` end** | explicitly. It is never a bridge member, so nothing propagates to it, and it is the end that determines the container's TCP MSS |

    An interface reporting **1470** has no remote address at all: with no destination the driver cannot know whether to reserve 20 bytes for IPv4 or 40 for IPv6, so it reserves 30.
    A 1470 overlay interface is misconfigured.

## Large transfers stall while pings answer { #fragment-drop }

**Symptom.**
A 56-byte ping is 0 % loss.
A 1472-byte ping is **100 % loss with no error printed**.
TCP connects (the handshake is small) and then stalls dead and dies on timeout.
The receiver got zero bytes.

**Check.**
The same counters as above, plus one more:

```sh
netstat -s -p ip | grep -iE 'fragment'      # look for "fragments dropped"
```

**Reading.**
`frags_rcvd +44 frags_dropped +44`, and nothing else anywhere.
This is the previous entry's too-large MTU **on top of a path that discards IP fragments**; cloud SDNs and stateful firewalls that drop fragments are common.

**Fix.**
Correct the MTU.
With the MTU right on the *same* hostile path, every probe passes and the transfer completes, because nothing needs fragmenting any more.
That is the entire point of getting the 50 bytes right.

!!! note "A receive-side MTU is not enforced"

    A node whose underlay MTU is *lower* than its peers' accepts oversized frames without counting an error; an interface MTU on FreeBSD is a transmit-side limit.
    Measured: with one node's underlay lowered to 1400 and the overlay at 1450, everything still works and `Ierrs` does not move.
    So a mismatched node shows up as fragmentation on its own outbound path and nowhere else.

## A task loses the network some time after a configuration change { #stale-arp }

**Symptom.**
Traffic that worked stops, with no error and no packet ever rejected, 100 % loss to one address, indefinitely.

**Check**

```sh
satl network inspect <network>          # is the gateway still there?
```

**Reading.**
A cached ARP entry pointing at a MAC that no longer answers.
Removing a network's gateway address from under running tasks is a **silent black hole**: the jail's cached entry survives, so packets keep being sent to a MAC that is gone, until the entry expires.

**Fix.**
Tear the endpoints down first, then change the addressing.
Recreating the task is what clears its ARP table.

!!! warning "An overlay's gateway is per node, and that is load-bearing"

    Every participating node's bridge is on **one** L2 segment, so a single shared gateway address would be a duplicate address on that segment.
    Measured with the same address on two nodes:

    ```
    node1 kernel: arp: 58:9c:fc:10:e5:0e is using my IP address 10.99.0.1 on expm3-br0!
    node1 kernel: arp: 10.99.0.1 moved from 58:9c:fc:10:a8:9b to 58:9c:fc:10:e5:0e
    ```

    Node 1's jail resolved its own gateway to **node 2's** MAC, and all three of its DNS queries were answered by node 2's responder while node 1's own responder received nothing.
    The same address is also the jails' default route, so whichever host wins the ARP race receives that jail's egress traffic too.

    SatL therefore allocates one gateway per node per overlay network, and `.1` of the subnet is **reserved and handed to nobody**.
    Reading `10.100.0.1` in a subnet is never one arbitrary node's address.
    `network inspect` reports **this node's** gateway, and a node running no task on the network reports no `Gateway` at all.

## A service name does not resolve, or resolves to the wrong service { #dns }

**Symptom.**
A container cannot resolve a service name on an overlay it is attached to, or resolves it and reaches the wrong service.

**Check**

```sh
satl exec <container> cat /etc/resolv.conf     # one nameserver per attached network
satl service ps <service>                      # are any tasks actually RUNNING?
sockstat -4l | grep ':53'                      # on the node: one socket per (node, network)
```

**Reading**

| Outcome | Meaning |
| --- | --- |
| the target service has no `RUNNING` task | correct: the responder only answers with `RUNNING` tasks. A service whose tasks are all `STARTING` (waiting on a first healthcheck) resolves to nothing |
| one `nameserver` line, but the service lives on the container's *other* network | not the cause: the responder identifies the querying task by source address and answers from **every** network it is attached to, whichever line the stub resolver picked |
| the name exists on two of the task's networks | the answer comes from **one** of them (the first the service spec lists), and is never a merge of the two |
| a name that is on none of them | `NXDOMAIN` if the node has no upstream resolver configured, otherwise whatever the upstream says, relayed verbatim |
| the container hardcodes another node's gateway address | its queries are **forwarded upstream instead of being answered**; a query whose source is not one of the node's own tasks is never answered from the table |

**Fix.**
Attach the service to a network the client is on, wait for a task to be `RUNNING`, or stop pointing the container at another node's responder.
Note that the qualified `<name>.<network>` form is **not implemented**; an unqualified name is the only form, so a service must be uniquely named across a task's networks to be addressable unambiguously.

## The counters live in two different stacks { #two-stacks }

This is not an entry; it is the rule that decides whether any of the numbers
above mean what you think they mean.

The TCP endpoints are inside VNET jails, so:

- **the jail's stack owns the retransmit and inner-IP statistics**, and the
  host's `netstat` knows nothing about them;
- **encapsulation happens on the host stack**, so the outer-IP fragmentation
  counters are the **host's**.

Reading the wrong one of the two is the fastest route to a confident wrong
conclusion; it happened while the reference measurements were being taken.

Getting at the jail's side needs care, because **a container image generally ships no diagnostic tools**: the FreeBSD-based test rootfs has neither `netstat` nor `arp`, and an Alpine one has only busybox, whose `netstat` reads `/proc/net/*` and whose `arp` speaks a Linux ioctl.
So `jexec <task> netstat -s -p tcp` works against a jail built from a full FreeBSD userland and not against a real container.
For a real container, put a throwaway `path=/` jail on the same bridge and measure from there, or read what the host can see; the VXLAN and epair counters and the fragmentation counters are all the host's anyway.

??? note "Reconciling the two, worked"

    From a 64 MiB transfer between two jails: sender host `vxlan.opkts` minus receiver host `vxlan.ipkts` gives the frames that went missing: 209 in one run, 208 in another, about 0.4 % of ~49 000 frames.
    In the first run the sender *jail's* `tcp.rexmit` was 209, matching exactly; in the second it was 1047, because retransmission is not one-to-one with loss (an RTO can resend more than was actually lost).

    So **the missing-frame count is the measure of loss and the retransmit counter is only its upper bound**.
    In every run, the VXLAN interface's `ierrs/idrop/oerrs` and the underlay's `ierrs/idrop/iqdrops` were 0 on both nodes; nothing in either guest dropped anything, and every byte still arrived.
    Packet counts across a tunnel are only meaningful next to the byte counts, the retransmit counter, and a bare-underlay control transfer run in the same session.

## Verifying an encrypted network, and watching rotation { #encrypted }

Everything above applies to a network created with `--opt encrypted`, with
three twists: its VTEP binds its **own port from 4790–4999** rather than
sharing 4789, its frames cross the underlay as **ESP (IP protocol 50)**, and
its MTU budget is underlay − 84 (1416 on 1500), so the
[fragmentation](#fragmentation) math moves with it.

**Verifying the wire.**
Between two nodes running tasks of the network, everything on the network's port must be ESP; the UDP capture must print nothing:

```sh
sudo tcpdump -ni <underlay-if> proto 50                 # the ESP flow itself
sudo tcpdump -ni <underlay-if> udp port <4790..4999>    # must print NOTHING
sudo setkey -D | head                                   # the SAs this node holds
sudo setkey -DP                                         # the outbound policies
```

To watch the *decapsulated* packets during a capture, present them to bpf on `enc0` too: `sudo sysctl net.enc.in.ipsec_bpf_mask=2`, then `tcpdump -ni enc0 udp port <port>`.
(`satld` sets the *filter* mask, the one pf sees, itself; the bpf mask is a capture-time knob for you.)

**A cleartext probe is supposed to die.**
The `satl/guard` anchor blocks cleartext UDP to 4790–4999 on the underlay and passes only what arrives decapsulated on `enc0`.
If you flush a node's SAs and ping across, the probe shows 100 % loss *and* nothing decapsulates onto the overlay bridge; the evidence is the block rule's counter moving (`pfctl -a satl/guard -sr`), not the ping.
The node's security reconcile is level-triggered and runs at least once a minute, so a flushed guard, SA or SP converges back within a minute; if it does not, the node's log names the `sysctl`/`ifconfig`/`pfctl`/`setkey` call that failed.

**Rotation is logged on the leader only.**
Keys rotate every 12 h by default, and the `keyring transition` lines (`phase=generate|append|promote|prune`, with the network name) appear in exactly one manager's log; grep **all** managers before concluding rotation is stuck, and remember `/var/log/messages` rotates roughly hourly (`bzcat messages.*.bz2 | grep -a`):

```sh
sudo grep -a 'keyring transition' /var/log/messages    # run on each manager
```

**One permanent side effect, by design.**
On the first encrypted network a node hosts, `satld` sets `net.enc.in.ipsec_filter_mask=2` and brings `enc0` up, node-wide, once, and deliberately never restored when the last encrypted network leaves.
That is the design, not a leak.

## `if_vxlan` is not in the GENERIC kernel { #kldload }

**Symptom.**
The first overlay network on a fresh host fails to program, and the log carries a `kldload` failure.

**Check**

```sh
kldstat -m if_vxlan
```

**Fix.**
`satld` runs `kldload -n if_vxlan` itself before creating the first VTEP, so an overlay works on an unprepared host.
Load it at boot anyway, so a failure surfaces once, at boot, rather than on the first `satl network create -d overlay`:

```sh
echo 'if_vxlan_load="YES"' | tee -a /boot/loader.conf   # sysrc(8) is for rc.conf, not loader.conf;
                                                        # `>>` under doas/sudo opens the file as you
kldload if_vxlan
kldstat -m if_vxlan                                     # expect one line
```
