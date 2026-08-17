# Compose files

`satl compose up` reads a Compose file and deploys it.
What it deploys is the part worth reading this page for: **services, not containers** — and that is a different thing from what `docker compose up` does on your laptop.

```sh
cd /srv/shop              # compose.yaml lives here, so the project is "shop"
satl compose config       # what would be created, as JSON — reaches no daemon
satl compose up           # networks first, then one service per compose service
satl compose ps           # this project's tasks, across the cluster
satl compose down         # removes exactly what `up` created
```

!!! tip "`satl stack` is the same machinery under Docker's verb names"

    `satl stack deploy -c compose.yaml shop` is `compose up` with the stack name as the project, `stack rm` is `down`, `stack config` is `config`, and `stack ls` / `stack services` / `stack ps` read the project label off the services.
    Docker's default applies on `deploy`: `--prune` is on unless said otherwise (compose's `up` keeps its explicit `--remove-orphans`).
    See the [`satl stack`](../reference/cli/stack.md) reference.

## It has stack semantics, not `docker compose` semantics

Docker has two worlds: `docker compose` makes containers on one host, and `docker stack deploy` makes services on a swarm.
SatL has only the second, because it has no standalone container — [every container is a task of a service](containers-and-services.md), and the cluster is always on.

So a compose file here necessarily becomes:

- **one service per compose service**, replicated to `deploy.replicas` (default
  1), not one container;
- **on a shared overlay network** created for the project, not a per-project
  bridge;
- **scheduled across the cluster** by the ordinary scheduler, so a three-replica
  service lands on up to three different nodes.

!!! warning "The consequences of that, in one list"

    - Service objects are named `<project>_<service>`, networks
      `<project>_<key>`, volumes `<project>_<key>` — so `satl service ls` shows
      `shop_web`, not `web`.
    - `deploy:` is **honoured**, where `docker compose` ignores it.
    - `container_name:`, `scale:` and the rest of the single-host half of the
      Compose Spec are **refused**, not ignored.
    - The number of containers is `deploy.replicas`.
      There is no `--scale`.
    - `up` never attaches, and there is no `satl compose logs`.

`satl compose --help` says the same thing, deliberately: a familiar command that
does something else owes you the warning before you type it.

### Hostnames keep working anyway

The namespacing would break the file's own hostnames — `shop_redis` does not answer to `redis:6379`.
So every attachment `up` creates carries the bare compose service name as a **DNS alias**, which is exactly what `docker stack deploy` does, and SatL's [DNS responder](networks.md#container-dns) resolves an alias like a service name.
Per-network `aliases:` are appended after it.

The one thing to watch: two projects sharing one **external** network cannot both declare a service of the same name, because the alias would be ambiguous and DNS round-robin would answer with tasks of both.
Give each project its own network — which is the default — or rename the service.

## A file that works

```yaml title="/srv/shop/compose.yaml"
name: shop

services:
  web:
    image: registry.example.com/freebsd-nginx:1
    ports:
      - "8080:80"
    networks: [front]
    configs:
      - source: nginx_conf
        target: /usr/local/etc/nginx/nginx.conf
    healthcheck:
      test: ["CMD-SHELL", "fetch -qo /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 10s
    deploy:
      replicas: 3
      update_config:
        parallelism: 1
        monitor: 10s
      placement:
        constraints:
          - node.role == worker

  redis:
    image: registry.example.com/redis:7
    networks: [front]
    secrets:
      - source: redis_auth
        target: auth.conf
        mode: 0440

networks:
  front:

configs:
  nginx_conf:
    external: true

secrets:
  redis_auth:
    external: true
```

```console
$ satl compose up
network shop_front created
service shop_web created
service shop_redis created
```

That file also happens to be the **only way to declare a healthcheck from the
CLI** — `satl service create` has no `--health-*` flags at all (see
[Healthchecks](healthchecks.md#defining-one)).

## The supported subset

Read per service:

`image` · `command` · `entrypoint` · `environment` · `env_file` · `ports` ·
`volumes` · `secrets` · `configs` · `healthcheck` · `labels` · `user` ·
`working_dir` · `hostname` · `stop_signal` · `stop_grace_period` · `restart` ·
`networks` · `depends_on`

and under `deploy:`: `mode` · `replicas` · `labels` · `resources` ·
`placement` · `restart_policy` · `endpoint_mode` · `update_config` ·
`rollback_config`.

Top level: `name` · `services` · `networks` · `volumes` · `secrets` · `configs`.
`x-` extension keys are accepted and ignored, because the Compose Spec reserves them and a YAML anchor block usually lives in one.

### Anything else is refused, not ignored

!!! danger "A file that half-deployed would be worse than one that was refused"

    `docker stack deploy` prints `Ignoring unsupported options: …` and carries on.
    A 200-line file that silently deployed two thirds of itself is the trap this refusal exists to avoid.
    Every refusal names **the file, the place in it, and the reason**, and it happens before anything is created:

    ```console
    $ satl compose up
    Error: /srv/shop/compose.yaml: services.web.build: compose build: is not
    supported: build the image with `satl build` (or any builder that can push
    to a registry) and name the result with `image:`
    ```

    A key with no bespoke reason of its own still fails — with the list of keys
    that *are* read.

The four you are most likely to meet, bringing a file from a single host:

| What is in the file | Why it is refused | What to do |
| --- | --- | --- |
| `build:` | compose `build:` is not supported — builds are `satl build`'s job, not the deploy path's | build with `satl build` (or any builder that can push to a registry), then name the result with `image:` |
| `./conf:/etc/nginx` | a relative bind is a path on *your* workstation, not on the nodes | deliver the file as a `config:`, or use an absolute path that exists on every node |
| `${TAG}` | there is no interpolation, and passing it through literally would ask for the tag `${TAG}` | substitute before deploying, or generate the file |
| `driver: bridge` on a network | a stack spans the cluster and only the overlay driver does | drop it — the default is `overlay` — or use `satl network create -d bridge` for a node-local object |

Also refused, with a reason each: `privileged`, `cap_add`/`cap_drop`, `devices`,
`network_mode`, `profiles`, `extends`, `container_name`, `scale`, every
`cpu*`/`mem*`/`pids_limit`/`ulimits` key (use `deploy.resources:`), `sysctls`,
`init`, `pid`, `ipc`, `uts`, `userns_mode`, `security_opt`, `shm_size`, `tmpfs`,
`links`, `volumes_from`, `expose`, `dns`, `extra_hosts`, `logging`, `platform`,
`read_only`, `tty`, `stdin_open`, `stop_timeout`, `develop`, `pull_policy`,
`runtime`, every `cgroup*` key, `deploy.preferences`, and top-level `include`.

### No interpolation, and one file

- **`${TAG}` and `$TAG` are refused**, naming the line and the column.
  There is no `.env` loading, no `${VAR:-default}` grammar and no `--env-file` for the compose file itself.
  Compose's *escape* is applied, though: `$$` becomes a literal `$` in one text-level pass, so a command written for compose (`sh -c 'echo $$HOME'`) means the same thing here.
- **One `-f/--file`, and no merging.**
  No override file, no `include:`, no `extends:`.
  Docker's merge rules are intricate and a half-merge is worse than none.
- Discovery is Docker's: `compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml`, in that order, walking up from the working directory.
  The first directory holding a candidate wins; several candidates in one directory is a warning naming the winner.

## The project name is what `down` acts on

It comes from `-p`, else `COMPOSE_PROJECT_NAME`, else the file's `name:`, else the project directory's base name — Compose's own precedence.
Normalization is Compose's too: lowercase, then **delete** (not replace) every character outside `[a-z0-9_-]`, then trim leading `_`/`-`.
A directory called `my.app` is therefore the project `myapp`.
A name you pass explicitly must already be normalized, and is refused otherwise.

`up` labels every object it creates:

```
com.docker.compose.project = <project>
com.docker.compose.service = <compose service key>     # on services
com.docker.compose.network = <compose network key>     # on networks
```

!!! success "`down` cannot remove somebody else's service"

    `down` acts on **that label and nothing else**.
    An object with exactly the name this project would use, but without the label, belongs to someone else — and both `up` and `down` refuse to touch it:

    ```console
    $ satl compose up
    Error: network shop_front already exists and does not belong to project shop:
    satl compose only touches what it created (label com.docker.compose.project).
    Give the network another name in the file, or mark it `external: true` to use
    it as it is
    ```

    Because the label is the scope, `down` needs no compose file at all:

    ```sh
    satl compose down -p shop        # from anywhere, with nothing checked out
    ```

    Two projects can share a cluster safely, and cleaning up after one never
    reaches the other.

An **orphan** — a service still carrying the label that the file no longer declares — is warned about by `up` and removed only with `--remove-orphans`.
`down` removes it unconditionally, because `down` works from the label rather than from the file.

## A second `up` is a rolling update

Each service is reposted against the version `up` read, so the [rolling updater](rolling-updates.md) replaces its tasks under the service's own `deploy.update_config` policy.
Nothing is recreated from scratch, and nothing else in the stored spec is lost.

```console
$ satl compose up
network shop_front exists
service shop_web updated
service shop_redis updated
```

## `down` waits, and will not touch volumes

Removing a network while a task still holds it is [refused by the daemon](networks.md#removing-a-network), and the tasks of the services just removed take their stop grace period to become terminal.
So `down` retries the network delete against the daemon's own answer for up to 90 s, saying on stderr that it is waiting.

!!! warning "`-v/--volumes` is refused outright"

    A volume is a node-local ZFS dataset — one per node that ran a task — and volume labels are not persisted, so there is no label to scope a cluster-wide removal by and no single node to remove it from.
    The CLI speaks to a unix socket only, so there is no remote `--host` to aim at either.

    ```sh
    satl compose config              # prints the volume names this project uses
    ssh node2 satl volume ls
    ssh node2 satl volume rm shop_redis-data
    ```

**Volumes are declarations only** in the first place: nothing is created for a top-level `volumes:` entry.
A named volume is a dataset the agent makes on the node where a task first uses it, `driver:` must be `local`, and `driver_opts:` is refused.
A service that mounts one gets a warning that the data is per node and does not follow a rescheduled task.

## Secrets and configs must already exist

Only `external: true` is accepted.
A `file:` declaration is refused, and the refusal carries the recipe:

```console
$ satl compose up
Error: /srv/shop/compose.yaml: secrets.redis_auth.file: satl compose never creates
a secret from a file: a secret is immutable, so a later `up` could not update it
and a `down` must not delete it. Create it once with
`satl secret create redis_auth ./auth.conf` and mark it `external: true` here
```

That is not fussiness.
[A secret is immutable](secrets-and-configs.md#rotation-is-by-replacement) — `update` is a `501` — so a second `up` after editing the file would silently keep the old payload, and `down` would then have to decide whether to delete cluster secret material it did not know it owned.
Neither answer is one you want made for you.

`environment:` as a payload source is refused for a different reason: it would
pass the secret through `satl`'s own process environment.

References are resolved to store IDs with one `GET /secrets` / `GET /configs`
**before anything is posted**, so a missing secret fails before any service is
created rather than rejecting every task afterwards.

!!! note "A `mode:` is read as octal however you write it"

    This is a place where two YAML versions disagree silently.
    An unquoted `0440` reaches a YAML 1.2 parser as the decimal digits `440`; Docker's own parser resolves it as octal.
    SatL reads the digits as **octal** in both spellings, so `0440`, `"0440"` and `440` all mean `0o440` — the mode you wrote.
    The cost is that a bare `mode: 700` is `0o700` here and decimal 700 in Docker; the benefit is that nobody ever gets a wider mode than they typed.
    A digit outside 0–7 is refused.

## Two keys that behave differently from a single host

**`depends_on` is a warning, not an order.**
There is no startup ordering in a cluster scheduler — the orchestrator places every task as soon as it can.
The short form, and `condition: service_started`, are accepted with a warning naming the services; an undefined service name is an error.
`condition: service_healthy` and `service_completed_successfully` are **refused**, because an application that asks for them relies on them.
Retry the dependency in the container and give it a `healthcheck:`, which is what actually gates traffic here.
(Docker's own `stack deploy` drops `depends_on` silently, printing nothing at all.)

**Both `restart:` and `deploy.restart_policy:` are honoured**, the deploy policy winning and saying so — `docker stack deploy` drops `restart:` as unsupported.
`restart: no|always|on-failure[:N]` maps onto the swarm conditions `none|any|on-failure`; `unless-stopped` is refused, because nothing here distinguishes "stopped by an operator" from "stopped".

A few more mappings, so you know they are not dropped: `labels:` become the
**container's** labels and `deploy.labels:` the **service's** (Docker's own
split); `deploy.mode: global` becomes a global service;
`deploy.placement.max_replicas_per_node` becomes `Placement.MaxReplicas`;
`deploy.placement.preferences` accepts `spread: <descriptor>` (below);
`deploy.endpoint_mode` accepts `dnsrr` only, since [there is no
VIP](../docker-differences.md#you-expect-a-service-vip);
`healthcheck.disable: true` becomes no probe, a bare string becomes `CMD-SHELL`,
and a list not starting with `CMD`, `CMD-SHELL` or `NONE` is refused rather than
silently producing no probe.

## Placement preferences: the soft nudge

Constraints are hard — a node either matches or is out.
A placement *preference* only reorders the candidates, and the one strategy is `spread` over a descriptor's values:

```sh
satl service create --placement-pref spread=node.labels.zone --replicas 4 app:1
```

```yaml
deploy:
  placement:
    preferences:
      - spread: node.labels.zone
```

With four replicas over zones `a` and `b`, the scheduler puts two in each before it double-books one — where the default spread only counts nodes.
The descriptor is `node.id`, `node.hostname`, `node.labels.<key>` or `engine.labels.<key>`; nodes missing the label form one empty-value group, as Docker's.
A preference never makes a node ineligible — it is a nudge, not a filter, and a one-group cluster schedules exactly as without it.

## The four subcommands, and the ones that are absent

| Command | What it does |
| --- | --- |
| `satl compose up` | creates the networks, then one service per compose service. `-d` is accepted and is a no-op: `up` is always detached |
| `satl compose down` | removes every object labelled with the project |
| `satl compose ps` | the project's tasks, across the cluster — the same table as `satl service ps`, scoped by the project label |
| `satl compose config` | prints the resolved **specs**, as JSON, without reaching the daemon |

`satl compose config` is worth a habit.
It does not print the merged compose file as Docker's does; it prints what `up` will post — the namespaced names, the DNS aliases, the project labels, the nanosecond durations and the ingress ports.
That is where the surprises are.
`--quiet` validates and prints nothing.

Absent by design: `build`, `pull`, `run`, `exec`, `restart`, `stop`/`start`, `top`, `events`, `logs`, `--wait`, `--profile`.
`up` is always detached because a cluster-wide log stream needs a log broker that does not exist yet.

## When a stack does not come up

--8<-- "ops-log-first.md"

1. `satl compose config` — did the file even resolve to what you meant?
2. `satl compose ps` — the task states and the node each one landed on.
3. Then the daemon's own account, **on the node holding the failing task**.

A task stuck in `Preparing` is usually an image that node cannot pull — and note that a [registry credential does not reach a service's own pull](images.md#authentication).
A `Rejected` task names its reason (a missing bind source, a secret whose `uid` is not numeric).
A task that starts and dies under a healthcheck is `Failed`, with the probe's exit code in the `ERROR` column of `satl compose ps`.

The full list of deviations, numbered and dated, is entries 110–124 of
`docs/api-compat.md` in the SatL source tree.
