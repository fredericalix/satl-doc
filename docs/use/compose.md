# Compose files

SatL reads a Compose file in two scopes, and you pick which by the verb you type.

- **`satl compose`** runs the whole file on the node you are talking to. That is
  `docker compose`'s scope.
- **`satl stack deploy`** spreads the same file across the cluster, on an
  overlay, placed by the scheduler. That is `docker stack deploy`'s scope.

Same file, same planner. What changes is where the tasks run, and therefore what
the file is allowed to say.

```sh
cd /srv/shop              # compose.yaml lives here, so the project is "shop"
satl compose config       # what would be created, as JSON
satl compose up           # deploys, then attaches to the output (^C detaches)
satl compose up -d        # ... or returns instead. Scripts want this
satl compose ps           # this project's tasks, all on this node
satl compose logs --follow
satl compose down -v      # remove what up created, volumes included
```

!!! warning "This changed in 0.2.0"

    Before 0.2.0, `satl compose up` did what `satl stack deploy` does now: it
    deployed across the cluster. If you have a project from an older release,
    either `satl compose down` it with the old binary first, or keep it on the
    cluster with `satl stack deploy`. The object names differ between the two,
    so the new verb will not adopt the old project.

## What does not change: every container is a task of a service

Neither verb makes a standalone container. There is no such thing here
([every container is a task of a service](containers-and-services.md)), so both
create **one service per compose service**, and both honour `deploy:` rather
than ignoring it. The number of containers is `deploy.replicas`, not one.

That is the part people expect to differ and it does not. What differs is scope.

## The two scopes, side by side

| | `satl compose` | `satl stack deploy` |
| --- | --- | --- |
| Where tasks run | this node, pinned | any eligible node |
| Object names | `<project>-<service>` | `<project>_<service>` |
| Project network | `bridge`, scope local | `overlay`, scope swarm |
| Published ports | on this node | the ingress routing mesh |
| `deploy.placement:` | refused | honoured |
| Relative bind `./conf:/etc/nginx` | honoured | refused |
| `build:` | builds a Satlfile here | refused |
| `up` | attaches; `-d` returns | always detached |
| `stop`/`start`/`restart`/`logs` | yes | no |

The hyphen and the underscore are docker's own split, not ours: compose v2 names
*containers* with a hyphen, `docker stack deploy` names *services* with an
underscore.

### Hostnames keep working in both

Namespacing would break the file's own hostnames; `shop-redis` does not answer
to `redis:6379`. So every attachment carries the bare compose service name as a
**DNS alias**, which is what `docker stack deploy` does too. SatL's
[DNS responder](networks.md#container-dns) resolves an alias like a service
name, and per-network `aliases:` are appended after it.

!!! danger "A compose project is not an isolation boundary"

    SatL programs **one bridge per node**, not one per network. Two projects on
    "different" bridge networks therefore share one L2 segment and can reach
    each other by address. Service *names* are scoped per project, so `redis` in
    one project never resolves to another's. Addresses are not scoped.

    When isolation is the requirement, use separate nodes, or an overlay through
    `satl stack deploy`.

## A file that works

```yaml title="/srv/shop/compose.yaml"
name: shop

services:
  web:
    image: registry.example.com/freebsd-nginx:1
    ports:
      - "8080:80"
    volumes:
      - "./conf:/usr/local/etc/nginx"
    configs:
      - source: nginx_conf
        target: /usr/local/etc/nginx/nginx.conf
    healthcheck:
      test: ["CMD-SHELL", "fetch -qo /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 10s

  redis:
    image: registry.example.com/redis:7
    secrets:
      - source: redis_auth
        target: auth.conf
        mode: 0440

configs:
  nginx_conf:
    external: true

secrets:
  redis_auth:
    external: true
```

```console
$ satl compose up -d
network shop-default created
service shop-redis created
service shop-web created
```

That file also happens to be the **only way to declare a healthcheck from the
CLI**; `satl service create` has no `--health-*` flags at all (see
[Healthchecks](healthchecks.md#defining-one)).

## What running on one node buys you

Four things the cluster scope cannot give, all for the same reason: the task
runs on the node you are talking to, and `satl` speaks a unix socket, so that
node's filesystem is the one you are looking at.

**A relative bind means what it says.** `./conf:/usr/local/etc/nginx` is
resolved against the project directory. `~` is expanded; `~user` is not, and is
refused rather than guessed.

**`build:` builds an image here.** See below.

**`down -v` can remove the volumes.** There is one node to remove them from.

**`up` can attach, and there is a `logs` verb.** Task output is node-local, so
following a whole project only works when the project is on one node.

## Building images

A service may declare `build:` instead of `image:`. The image is tagged
`<project>-<service>:latest`, or `image:` when you give one, and used straight
from this node's store — **no registry involved**, because the task that uses it
is pinned to the node that built it.

```yaml
services:
  app:
    build: ./app          # ./app/Satlfile
```

```sh
satl compose build          # build without deploying
satl compose up --build     # build, then deploy
```

!!! warning "It builds a `Satlfile`, not a Dockerfile"

    SatL's builder reads a [`Satlfile`](images.md#satl-build): the subset of
    Dockerfile verbs that makes sense for pkg-based FreeBSD images. `dockerfile:`
    keeps compose's key name, because that is the key people type, but it only
    says *which file to read*. The file's contents must be Satlfile syntax.

    Refused with a reason each, because the builder genuinely cannot honour
    them: `args:` (a Satlfile has no `ARG`), `target:` (several stages are
    allowed, but the last is always the one packed), `cache_from`, `ssh`,
    `secrets`, `platform`, `network` and `tags`.

    Both verbs need **root**, because writing to the image store does.

Two behaviours worth knowing. Rebuilding under the same tag *does* replace the
running tasks: SatL stamps the new image's digest into the service so the
rolling updater picks it up. And the builder is not reproducible — two builds of
an unchanged tree differ — so `--build` replaces the tasks every time, not only
when something changed.

## Managing a running project

None of these three is docker's, and none of them can be: a task is one-shot and
is never paused and resumed.

| Command | What it does |
| --- | --- |
| `satl compose stop` | scales every service to 0 replicas, keeping the services, the network and the volumes |
| `satl compose start` | scales them back to what **the file** says |
| `satl compose restart` | replaces the tasks, under each service's own update policy |

`start` therefore needs the compose file, where `stop` does not. That is
deliberate: nothing is stashed in a hidden label, so a `start` from another
checkout restores a number you can read. And `restart` brings tasks back with
**new ids** in the same slots, because a replacement is what "restart" means
here.

`satl compose up --scale web=3` overrides the file's replica count for one run.
It is held to the same rules the file is; see the host-port refusal below.

## Following the output

`satl compose up` attaches unless you pass `-d`. Each line is prefixed with
`<service>-<slot>`, one colour per service on a terminal and none when
redirected.

```console
$ satl compose logs --follow
web-1   | 2026/08/24 12:29:58 [notice] start worker processes
redis-1 | Ready to accept connections
```

!!! warning "Ctrl-C detaches; it does not stop the project"

    `docker compose up` stops the containers on the first Ctrl-C. Here the
    project is already deployed by the time attaching begins, so a keystroke
    does not undeploy it. Use `satl compose stop`.

    `--follow` has no `-f`, because at this level `-f` is already `--file`.

## The supported subset

Read per service:

`image` · `build` · `command` · `entrypoint` · `environment` · `env_file` ·
`ports` · `volumes` · `secrets` · `configs` · `healthcheck` · `labels` · `user` ·
`working_dir` · `hostname` · `stop_signal` · `stop_grace_period` · `restart` ·
`networks` · `depends_on`

and under `deploy:`: `mode` · `replicas` · `labels` · `resources` ·
`placement` · `restart_policy` · `endpoint_mode` · `update_config` ·
`rollback_config`.

Top level: `name` · `services` · `networks` · `volumes` · `secrets` · `configs`.
`x-` extension keys are accepted and ignored, because the Compose Spec reserves
them and a YAML anchor block usually lives in one.

### Anything else is refused, not ignored

!!! danger "A file that half-deployed would be worse than one that was refused"

    `docker stack deploy` prints `Ignoring unsupported options: …` and carries
    on. A 200-line file that silently deployed two thirds of itself is the trap
    this refusal exists to avoid. Every refusal names **the file, the place in
    it, and the reason**, before anything is created:

    ```console
    $ satl compose up
    Error: /srv/shop/compose.yaml: services.web.deploy.placement: `satl compose`
    runs every task on the node you are talking to, so there is nothing left to
    place: a constraint or a preference could only make the service
    unschedulable. Deploy across the cluster with `satl stack deploy` to use it
    ```

    A key with no bespoke reason of its own still fails, with the list of keys
    that *are* read.

The four you are most likely to meet, bringing a file from a single host:

| What is in the file | Under `satl compose` | Under `satl stack deploy` |
| --- | --- | --- |
| `build:` | builds a `Satlfile` | refused: build it once and `--push` it |
| `./conf:/etc/nginx` | honoured | refused: that path is not on the nodes |
| `${TAG}` | refused, everywhere | refused, everywhere |
| `driver: bridge` on a network | the default | refused: a stack needs the overlay |

Also refused, with a reason each: `privileged`, `cap_add`/`cap_drop`, `devices`,
`network_mode`, `profiles`, `extends`, `container_name`, `scale`, every
`cpu*`/`mem*`/`pids_limit`/`ulimits` key (use `deploy.resources:`), `sysctls`,
`init`, `pid`, `ipc`, `uts`, `userns_mode`, `security_opt`, `shm_size`, `tmpfs`,
`links`, `volumes_from`, `expose`, `dns`, `extra_hosts`, `logging`, `platform`,
`read_only`, `tty`, `stdin_open`, `stop_timeout`, `develop`, `pull_policy`,
`runtime`, every `cgroup*` key, and top-level `include`.

### One host port, one node

`satl compose` publishes on the node it runs on, so a fixed host port can be
taken exactly once. Asking for more than one replica of a service that publishes
one is refused, rather than left with tasks that can never be placed:

```console
$ satl compose up
Error: /srv/shop/compose.yaml: services.web: 3 replicas with host port 8080
published: a host port can only be taken once on a node ...
```

Drop the fixed port (`"80"` alone publishes on an ephemeral one), ask for one
replica, or spread the service over the cluster with `satl stack deploy`.

### No interpolation, and one file

- **`${TAG}` and `$TAG` are refused**, naming the line and the column. There is
  no `.env` loading, no `${VAR:-default}` grammar and no `--env-file` for the
  compose file itself. Compose's *escape* is applied, though: `$$` becomes a
  literal `$` in one text-level pass.
- **One `-f/--file`, and no merging.** No override file, no `include:`, no
  `extends:`. Docker's merge rules are intricate and a half-merge is worse than
  none.
- Discovery is Docker's: `compose.yaml`, `compose.yml`, `docker-compose.yml`,
  `docker-compose.yaml`, in that order, walking up from the working directory.

## The project name is what `down` acts on

It comes from `-p`, else `COMPOSE_PROJECT_NAME`, else the file's `name:`, else
the project directory's base name, Compose's own precedence. Normalization is
Compose's too: lowercase, then **delete** every character outside `[a-z0-9_-]`,
then trim leading `_`/`-`. A directory called `my.app` is the project `myapp`.

`up` labels every object it creates:

```
com.docker.compose.project = <project>
com.docker.compose.service = <compose service key>     # on services
com.docker.compose.network = <compose network key>     # on networks
```

!!! success "`down` cannot remove somebody else's service"

    `down` acts on **that label and nothing else**. An object with exactly the
    name this project would use, but without the label, belongs to someone else,
    and both `up` and `down` refuse to touch it.

    Because the label is the scope, `down` needs no compose file at all:

    ```sh
    satl compose down -p shop        # from anywhere, with nothing checked out
    ```

An **orphan**, a service still carrying the label that the file no longer
declares, is warned about by `up` and removed only with `--remove-orphans`.
`down` removes it unconditionally, because `down` works from the label.

## A second `up` is a rolling update

Each service is reposted against the version `up` read, so the
[rolling updater](rolling-updates.md) replaces its tasks under the service's own
`deploy.update_config` policy. Nothing is recreated from scratch, and nothing
else in the stored spec is lost.

## `down` waits, and `-v` works on this node

Removing a network while a task still holds it is
[refused by the daemon](networks.md#removing-a-network), and the tasks of the
services just removed take their stop grace period to become terminal. So `down`
retries the network delete for up to 90 s, saying on stderr that it is waiting.

`satl compose down -v` then removes the volumes, last, for the same reason: a
volume a task still holds cannot go.

!!! note "`-v` reads the file; a plain `down` does not"

    Volume labels are not persisted, so there is nothing to scope a removal by.
    `-v` therefore takes the volume names from the **file** — the `<project>-<key>`
    names it declares — where the rest of `down` works from the project label.

    `satl stack rm` has no `-v` at all, as `docker stack rm` has none: a stack's
    datasets are on whichever nodes ran a task. Remove those where each daemon
    is: `ssh node2 satl volume rm shop_redis-data`.

## Secrets and configs must already exist

Only `external: true` is accepted. A `file:` declaration is refused, and the
refusal carries the recipe:

```console
$ satl compose up
Error: /srv/shop/compose.yaml: secrets.redis_auth.file: satl compose never creates
a secret from a file: a secret is immutable, so a later `up` could not update it
and a `down` must not delete it. Create it once with
`satl secret create redis_auth ./auth.conf` and mark it `external: true` here
```

That is not fussiness. [A secret is immutable](secrets-and-configs.md#rotation-is-by-replacement),
so a second `up` after editing the file would silently keep the old payload.
`environment:` as a payload source is refused for a different reason: it would
pass the secret through `satl`'s own process environment.

!!! note "A `mode:` is read as octal however you write it"

    An unquoted `0440` reaches a YAML 1.2 parser as the decimal digits `440`;
    Docker's own parser resolves it as octal. SatL reads the digits as **octal**
    in both spellings, so `0440`, `"0440"` and `440` all mean `0o440`. A digit
    outside 0–7 is refused.

## Two keys that behave differently from a single host

**`depends_on` is a warning, not an order.** There is no startup ordering: the
orchestrator places every task as soon as it can. The short form, and
`condition: service_started`, are accepted with a warning naming the services;
an undefined service name is an error. `condition: service_healthy` and
`service_completed_successfully` are **refused**, because an application that
asks for them relies on them. Retry the dependency in the container and give it
a `healthcheck:`, which is what actually gates traffic here.

**Both `restart:` and `deploy.restart_policy:` are honoured**, the deploy policy
winning and saying so; `docker stack deploy` drops `restart:` as unsupported.
`restart: no|always|on-failure[:N]` maps onto the swarm conditions
`none|any|on-failure`; `unless-stopped` is refused, because nothing here
distinguishes "stopped by an operator" from "stopped".

A few more mappings, so you know they are not dropped: `labels:` become the
**container's** labels and `deploy.labels:` the **service's**; `deploy.mode:
global` becomes a global service; `healthcheck.disable: true` becomes no probe;
a bare string becomes `CMD-SHELL`; and a list not starting with `CMD`,
`CMD-SHELL` or `NONE` is refused rather than silently producing no probe.

## Deploying the same file across the cluster

Everything above describes `satl compose`. The cluster verb is `satl stack`, and
it is the same machinery with the other scope:

```sh
satl stack deploy -c compose.yaml shop
satl stack ls
satl stack services shop
satl stack ps shop
satl stack rm shop
```

`--prune` defaults on for `stack deploy`, as Docker's does, where `compose up`
requires the explicit `--remove-orphans`. See the
[`satl stack`](../reference/cli/stack.md) reference.

Placement is the clearest thing that only works there. A constraint is hard; a
**preference** only reorders the candidates, and the one strategy is `spread`
over a descriptor's values:

```yaml
deploy:
  placement:
    constraints:
      - node.role == worker
    preferences:
      - spread: node.labels.zone
```

With four replicas over zones `a` and `b`, the scheduler puts two in each before
it double-books one. The descriptor is `node.id`, `node.hostname`,
`node.labels.<key>` or `engine.labels.<key>`.

## When a project does not come up

--8<-- "ops-log-first.md"

1. `satl compose config`: did the file even resolve to what you meant?
2. `satl compose ps`: the task states.
3. `satl compose logs`: what the tasks themselves said.
4. Then the daemon's own account, on the node holding the failing task.

A task stuck in `Preparing` is usually an image that node cannot pull, and note
that a [registry credential does not reach a service's own pull](images.md#authentication).
A `Rejected` task names its reason. A task that starts and dies under a
healthcheck is `Failed`, with the probe's exit code in the `ERROR` column.

!!! note "`satl compose up` needs a manager"

    Every `/services` mutation is refused on a worker node, so `satl compose up`
    there fails the same way `satl run` does. Run it on a manager.

The full list of deviations, numbered and dated, is entries 110–124 and 169–182
of `docs/api-compat.md` in the SatL source tree.
