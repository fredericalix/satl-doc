# What SatL is

SatL is a container engine for FreeBSD with the orchestrator already inside it.

Three sentences describe the whole thing:

- **Containers are jails.**
  SatL pulls OCI images, applies their layers as ZFS datasets, generates an OCI runtime spec, and hands it to the `ocijail` binary to create, start, kill and delete a jail.
  SatL implements no runtime of its own and never will.
- **Orchestration is built in.**
  Every node runs one daemon, `satld`.
  On a manager, that daemon holds a Raft-replicated store, a scheduler and the reconciliation loops; on every node it also runs the agent that executes tasks.
  There is no second thing to install, no separate control plane to operate, no etcd.
- **The surface is Docker's.**
  `satld` serves the Docker Engine REST API (v1.43, negotiable down to 1.24) on a unix socket, and `satl` is a Docker-compatible CLI over it.
  `docker -H unix:///var/run/satl.sock version` works.
  Where SatL deviates from Docker's semantics, the deviation is written down rather than discovered.

## The sentence that reframes everything

> **A single node is a cluster of one, and every container is a task of a
> service.**

This is not a slogan; it is the data model, and almost every surprise a Docker
user meets in SatL follows from it.

A fresh `satld` does not wait for `swarm init`.
On first boot it mints a node identity, a cluster identity and a root certificate authority, initialises a one-member Raft cluster, and starts scheduling against it.
`GET /info` reports `Swarm.LocalNodeState: active` and `ControlAvailable: true` from the very first start, where Docker would say `inactive`.
Adding a second machine later is a `satl swarm join`, not a migration.

And there are no standalone containers.
`satl run` creates an anonymous single-replica **Service**, the orchestrator creates one **Task** under it, the scheduler places that task on a node, and the node's agent runs it as a jail.
What `satl ps` lists are tasks, rendered in Docker's container shape.

```console
$ satl service ls
ID             NAME             MODE         REPLICAS   IMAGE                                           PORTS
2kjm40q4jy14   web              replicated   1/1        127.0.0.1:5000/satl-test/freebsd-nginx:latest   *:8080->80/tcp
1qb4wykhu6fw   hopeful_rhodes   replicated   0/1        127.0.0.1:5000/satl-test/alpine
```

`web` was created with `satl run --name web`.
`hopeful_rhodes` was created by a bare `satl run` that has since exited; the generated name is the giveaway.
Both are services, because there is nothing else for them to be.

## What the model buys

**One orchestrator, or none, is not a choice you have to make.**
The single-machine story and the cluster story are the same story.
There is no "development mode" that behaves differently from production, no `docker-compose` on one host and Swarm on three, no moment where you rebuild your mental model because you added a machine.
A scheduler that has been placing tasks since first boot places them the same way when there are three nodes.

**Desired state is the only state you set.**
You do not start containers; you declare that a service should have four replicas of an image, and the reconciliation loops make that true and keep it true.
A node dies and its replicas are recreated elsewhere.
A container exits and the restart policy decides.
A rolling update replaces tasks under a policy you set, and rolls itself back if the new image fails.
None of that is a feature bolted onto a container runtime; it is the only path a container has ever taken.

**Every lifecycle transition is a state-machine step with a name.**
A task walks `NEW → PENDING → ASSIGNED → ACCEPTED → PREPARING → READY → STARTING → RUNNING` and ends `COMPLETE`, `FAILED` or `SHUTDOWN`.
Each transition is logged with the task, service and node ids on it, which is why diagnosing SatL means grepping the log by identity rather than reading it by time.

**The API stays honest.**
Because a container is a task, options SatL cannot honour are refused with a 400 instead of accepted and ignored: `Privileged`, `CapAdd`, `Devices`, `CgroupParent`, `Sysctls`, `Ulimits`, `PidMode` and the rest.
A half-honoured isolation flag is a security trap; SatL would rather fail your `docker run` than pretend.

## What the model costs

This is the part worth reading before you install anything.

!!! warning "A stopped container cannot be restarted"

    There is no `satl start` verb at all, and the REST API answers **409** to `POST /containers/{id}/start` on a container that has already run.
    A task is one-shot and immutable: running it again would mean a *new* task, which is a new container id, which is not something Docker's API can express.
    `docker start` therefore works only on a container that was created and never started.

    What you do instead: `satl run` again, or, if the thing should be running
    continuously; make it a service and let the restart policy own it.

!!! warning "`satl rm` removes the backing service"

    Removing a container removes the Service behind it as well.
    It has to: leave the service in place and the orchestrator immediately refills the empty slot with a new task, and you have removed nothing.
    So `satl rm web` is closer to `docker service rm web` than to `docker rm web`.

Three smaller consequences of the same shape:

- **`stop -t` and `kill --signal` do not do what you expect.**
  The stop grace period and the stop signal live in the task spec, which is immutable after creation, so `POST /containers/{id}/stop?t=` is ignored and `kill` performs a graceful shutdown rather than sending the signal you named.
- **Container ids are 25-character base36 task ids**, not 64 hex characters, and `Names` is `["/<service name>"]`.
  Anything that pattern-matches Docker id shapes will not recognise them.
- **Networks cannot be hot-plugged.**
  `POST /networks/{id}/connect` and `/disconnect` answer 501.
  A task's network attachments are allocated once, at creation, from the same immutable spec.

??? note "Why not make a container a Service instead of a Task?"

    It would fit Docker's semantics better (`start` after `stop` would create a fresh task under a stable id), and it is recorded in SatL's own `docs/api-compat.md` as a deliberate, reversible choice rather than an oversight.
    The cost is that every container would then carry a full service spec and an update policy it never uses.
    The decision is still open.

## Where SatL stops

Three boundaries are worth knowing early, not as disclaimers, but because each
one tells you which tool to reach for next.

- **It is close to Docker Swarm, and that is the point, but the data plane is FreeBSD's.**
  The orchestration follows SwarmKit's behavioural model deliberately closely: the same task states, the same restart and update semantics, the same join-token scheme, and a real ingress [routing mesh](../use/publishing-ports.md#the-routing-mesh-every-manager-answers) where every manager answers every published port.
  What differs is underneath.
  FreeBSD has no IPVS, so there is **no service VIP**, discovery is DNS round-robin, and the mesh is built from `pf` redirects, which makes it managers-only rather than every-node.
  [Why FreeBSD](why-freebsd.md) has the full accounting of what the substrate gives and withholds.
- **`satl build` is the FreeBSD image tool, not a Dockerfile engine.**
  It builds real images and is meant to be used: multi-layer, multi-stage with `COPY --from`, `FROM scratch`, a content-addressed incremental cache (51 s cold, 7 s when nothing moved) and `--push` to a registry.
  What it is not is BuildKit; the format is the pkg-shaped subset of a Dockerfile, there is no daemon-side `POST /build`, and it does not build **Linux** images.
  Pull those from a registry and [run them under the linuxulator](../use/linux-containers.md).
- **It is not a runtime.**
  `ocijail` is.
  If a jail behaves oddly, the question is usually what SatL put in the OCI spec, not how SatL started the process, which is a much easier question to answer.

If you hit a fourth boundary we have not written down, that is worth telling us
about: [Before you report a problem](../trouble/getting-help.md) says what makes
a report useful, and the gaps people actually hit are the ones that get closed
first.

Next: [Why FreeBSD](why-freebsd.md) for what the substrate gives and withholds,
or [How it works](how-it-works.md) for the vocabulary and the shape of a
cluster.
