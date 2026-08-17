# Secrets and configs

A secret is a payload the cluster keeps encrypted and delivers into a container's memory.
A config is the same machinery without the secrecy — a file you want in `/etc` without baking it into an image.

```sh
printf 'hunter2' | satl secret create db_password -
satl config create app.conf ./app.conf

satl service create --name web \
    --secret db_password \
    --secret source=api_key,target=keys/api,uid=1000,gid=1000,mode=0400 \
    --config source=app.conf,target=/etc/app/app.conf \
    registry.example.com/app:1
```

--8<-- "ops-manager-only.md"

## Creating one

`satl secret create <name> <file>` reads the payload from a file, or from stdin when the file is `-`.
There is no flag that takes the value inline, deliberately: a secret on a command line is a secret in the shell history and in `ps` output.

```sh
printf 'hunter2' | satl secret create db_password -
satl secret create db_password ./password.txt
satl config create app.conf ./app.conf
```

`satl secret ls`, `satl secret inspect` and `satl secret rm` complete the set, and `satl config` mirrors all four.
**`inspect` returns metadata only** — the payload is never served back by the API, for either kind.

Size limits: **a secret payload is under 500 KiB, a config under 1000 KiB**.
The CLI enforces them before it encodes or sends anything (`secret data is N bytes; the limit is 500 KiB`), and the daemon enforces the same limits for raw API callers.

## Referencing one from a service

`--secret` and `--config` take Docker's syntax: a bare name, or a
comma-separated form.

```
--secret db_password
--secret source=api_key,target=keys/api,uid=1000,gid=1000,mode=0400
--config source=app.conf,target=/etc/app/app.conf
```

`src=` is an accepted alias for `source=`, keys are case-insensitive, and `mode`
is octal.

References are resolved by **ID**: the CLI lists the objects once to turn your name into an id before posting the spec.
A reference naming something that does not exist is refused at service-create time, rather than failing every task the service ever schedules.

`satl service update` has **no** `--secret-add`/`--secret-rm`/`--config-add`/ `--config-rm`.
Existing references survive an update untouched — the CLI reposts the stored spec — but changing the set needs the REST API.

## Where it lands inside the container

| | Secret | Config |
| --- | --- | --- |
| target | **relative**, rooted at `/run/secrets` | absolute, or relative and rooted at `/` |
| storage | a per-task tmpfs | a read-only nullfs file-mount |
| default mode | `0444` | `0444` |
| owner | `0:0` unless given | `0:0` unless given |

So `--secret db_password` puts the payload at `/run/secrets/db_password`, and
`--secret source=api_key,target=keys/api` puts it at `/run/secrets/keys/api`.

An **absolute** secret target is a 400:

```
invalid secret target /etc/api_key: secret target must be a relative path;
secrets are mounted under /run/secrets
```

Docker allows an arbitrary absolute path and bind-mounts the file there.
SatL delivers every secret through one per-task tmpfs, because a secret written anywhere else would be a secret on the node's disk.
A config target may be absolute — that is how a config lands in `/etc` — and neither kind may contain a `..` component.

!!! warning "`File.UID` and `File.GID` must be numeric"

    Docker resolves user and group *names* from the image's `/etc/passwd` and `/etc/group`.
    SatL does not read the image's user database, so a name is refused when the task is planned: the task goes `REJECTED` with a message naming the reference, rather than being silently owned by root.
    Use `uid=1000,gid=1000`.

??? note "`/run/secrets` is a writable tmpfs, and the file mode is the protection"

    Docker remounts its secret tmpfs read-only.
    SatL's is writable, with each file carrying the mode and ownership you asked for — so an unprivileged process in the jail cannot alter them, and root inside the jail can.
    The protection is the file mode, not the mount flag.
    Making the mount read-only needs a second mount pass after the files are written, which is not done yet.

## The guarantee

!!! success "A secret is encrypted at rest on managers, in memory only on workers"

    - **On managers**, the payload lives in the Raft store, and the whole Raft log and its snapshots are encrypted at rest with the node's [`dek`](../config/state.md#the-dek-file).
      There is no plaintext copy on a manager's disk.
    - **On workers**, the payload arrives over the mutually authenticated dispatcher stream, lives in the agent's memory, and is written **only** into the per-task tmpfs inside the jail.
      The node's local task database stores secret *references*, never payloads; after an agent restart the payloads are re-fetched from its session.
    - **The log never carries a payload.**
      Secret *names* appear (`materialized dependency payload`, `secret assigned/withdrawn`); the bytes do not.
      If a payload ever shows up in `/var/log/messages` that is a bug worth reporting — the integration suite greps for exactly that.

    Configs get the same delivery path without the secrecy claim: their payloads
    are written under the task's bundle directory on the node's disk before
    being mounted read-only into the jail.

## Rotation is by replacement

There is no update verb.
`satl secret` has `create`, `ls`, `inspect` and `rm`, and the REST endpoint says so:

```console
$ curl -s --unix-socket /var/run/satl.sock -X POST http://localhost/secrets/db_password/update
{"message":"secrets are immutable; rotate by creating a new secret, updating the services
that use it, and removing the old one"}
```

That 501 is the documented path, spelled out in the error itself.
Docker's own endpoint accepts a whole spec and honours only a change of `Labels` — the payload is immutable there too — and a 200 that silently ignored the `Data` you just sent is the worst of the three possible answers.

The rotation, in full:

```sh
# 1. create the new secret under a new name
printf 'new-password' | satl secret create db_password_v2 -

# 2. update the services that use it (this replaces their tasks)
satl service update --image <same or new> web     # + the spec change over the API

# 3. remove the old one, once nothing references it
satl secret rm db_password
```

Step 2 is what actually rotates anything: a running task holds the payload it was given at creation, in memory, and only a *new* task gets the new one.
Creating a secret changes nothing on its own.

!!! info "Step 2 needs the REST API today"

    `satl service update` has no flag for changing the secret set, so the spec edit has to go over `POST /services/{id}/update`.
    The task replacement it triggers is an ordinary [rolling update](rolling-updates.md) and obeys the service's update policy.

## Removal is refused while anything references it

```console
$ satl secret rm db_password
Error response from daemon: secret db_password is in use by the following
service(s): api, web. Update or remove them first
```

A 409, naming the services to fix first — at most four names, then "and N more".
Docker answers 400 here; SatL follows its own network precedent, because "the object exists but is in the wrong state" is what 409 means and it is what the CLI turns into a usable exit code.

"In use" is deliberately wider than Docker's check: it counts every service whose task template merely *references* the object — whose next task would be unpreparable — as well as every non-terminal task holding it.
A terminal task is history, not a use.

That refusal is what keeps a running task from losing a secret it was promised.
The dispatcher tolerates the race anyway — a secret deleted mid-flight is withdrawn from the nodes and logged — but in normal operation the API makes that path unreachable.

## What is refused, and why

| Field | Answer |
| --- | --- |
| `SecretSpec.Driver` | 400, "secret drivers are not supported". There are no driver plugins, so an external store cannot be honoured — and a secret quietly stored in the cluster instead would be exactly the leak the driver existed to prevent |
| `Templating` | 400 when its `Name` is non-empty, for both kinds. There is no template engine, and a config whose `{{ }}` placeholders were never expanded is a broken file delivered as a correct one |
| `File.Mode` above `0o7777` | 400. Go's `os.FileMode` has type bits above the permission bits, and SatL will not silently mask them |
| `?filters=` on list | 501 rather than ignored. Filter with the client |

`satl secret ls` prints Docker's `DRIVER` column, always blank, because Docker's layout has it.
IDs are printed in full — SatL ids are 25 characters, and there is no `--no-trunc` because nothing is truncated.
