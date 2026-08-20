# A real application: Node.js + MariaDB

From zero to a three-replica web app with a database, built, deployed and operated with SatL alone.
Every command and every output on this page was run on the three-node test cluster — the surprises it hit are left in, because they are the ones you will hit.

The app is a guestbook: a Node.js server that reads and writes a MariaDB table, three replicas behind a published port, the database pinned to one node with a node-local volume.
On the way it uses `satl build`, secrets, constraints, placement preferences, healthchecks, `satl stack`, the routing mesh, a rolling update and a hot resize.

## What you need

A SatL cluster: the [install](../start/install.md) and a `swarm join` per node.

And **[a local registry on every node](../start/registry.md)**, each seeded with the base image this page builds `FROM` — `127.0.0.1:5000/satl-test/freebsd-runtime:15.1`, exactly as [Your first container](../start/first-container.md) uses it.
On every node is not a formality: `127.0.0.1:5000` resolves to a different registry on each machine, and a node whose registry is missing the base image cannot build, while a node missing the *built* image cannot run a replica.
That is the shape of the whole page — every `satl build` below happens once per node.

## 1. The application

Two files.
`app/package.json`:

```json
{
  "name": "tuto-web",
  "version": "1.0.0",
  "private": true,
  "dependencies": { "mysql2": "^3.11.0" }
}
```

`app/server.js` — the interesting bits are where the password and the
database host come from:

```js
const http = require("http");
const fs = require("fs");
const os = require("os");
const mysql = require("mysql2/promise");

// The secret is a file, mounted by SatL on a per-task tmpfs.
const password = fs.readFileSync("/run/secrets/db_password", "utf8").trim();
// `db` resolves to the database's tasks — SatL's embedded DNS answers with
// the compose service name.
const pool = mysql.createPool({
  host: process.env.DB_HOST || "db",
  user: "guest",
  password,
  database: "guestbook",
});

async function init() {
  await pool.query(`CREATE TABLE IF NOT EXISTS messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    txt VARCHAR(255),
    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP)`);
}
const ready = init();

http.createServer(async (req, res) => {
  if (req.url === "/health") {
    try { await ready; await pool.query("SELECT 1"); res.writeHead(200); res.end("ok\n"); }
    catch (e) { res.writeHead(500); res.end("db down\n"); }
    return;
  }
  if (req.method === "POST" && req.url.startsWith("/add")) {
    const msg = new URL(req.url, "http://x").searchParams.get("msg") || "vide";
    await pool.query("INSERT INTO messages (txt) VALUES (?)", [msg.slice(0, 250)]);
    res.writeHead(302, { location: "/" }); res.end();
    return;
  }
  const [rows] = await pool.query("SELECT txt, created FROM messages ORDER BY id DESC LIMIT 20");
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(`<h1>Livre d'or SatL</h1>
<p>réplica: ${os.hostname()} — client: ${req.socket.remoteAddress}</p>
<ul>${rows.map(r => `<li>${r.txt}</li>`).join("")}</ul>`);
}).listen(8080, "0.0.0.0");
```

## 2. Building the image with `satl build`

The `Satlfile`, in the same directory as `app/`:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG node24 npm-node24
WORKDIR /srv/app
COPY app/ /srv/app/
RUN /usr/local/bin/npm install --omit=dev
ENV NODE_ENV=production
EXPOSE 8080/tcp
ENTRYPOINT ["/usr/local/bin/node", "/srv/app/server.js"]
```

`COPY` reads the Satlfile's own directory; `RUN` executes in a chroot of the
assembled rootfs — here that is what runs `npm install`, with the network,
before the image is packed.

```console
$ sudo satl build -t 127.0.0.1:5000/satl-test/tuto-web:latest
Built and registered 127.0.0.1:5000/satl-test/tuto-web:latest (manifest sha256:19eb1d9d…)
```

--8<-- "image-is-node-local.md"

This page takes the first road: the same `satl build`, run on each of the three nodes, because the test cluster's only registry is the loopback one and a loopback registry moves nothing between machines.
Copy the directory (`app/`, `Satlfile`) to each node and run the identical command there.

## 3. The database image

MariaDB needs an entrypoint that initialises the data directory on first start.
With `COPY` the script rides inside the image.
`db/db-entrypoint.sh`:

```sh
#!/bin/sh
set -e
DATA=/var/db/mysql
if [ ! -d "$DATA/mysql" ]; then
  /usr/local/bin/mariadb-install-db --user=mysql --datadir="$DATA" >/dev/null
fi
chown -R mysql:mysql "$DATA"
PASS=$(cat /run/secrets/db_password)
{
  echo "CREATE DATABASE IF NOT EXISTS guestbook;"
  echo "CREATE USER IF NOT EXISTS 'guest'@'%' IDENTIFIED BY '$PASS';"
  echo "GRANT ALL PRIVILEGES ON guestbook.* TO 'guest'@'%';"
  echo "FLUSH PRIVILEGES;"
} > $DATA/init.sql
exec /usr/local/libexec/mariadbd --user=mysql --datadir="$DATA" \
  --bind-address=0.0.0.0 --init-file=$DATA/init.sql --socket=/tmp/mysql.sock
```

Three things on this page were learned the hard way, and the logs showed each:

- `mariadbd` lives in **`/usr/local/libexec`**, not `sbin` — the first build
  failed with `exec: /usr/local/sbin/mariadbd: not found`;
- the default socket path `/var/run/mysql/` does not exist in a minimal
  image, so the socket is moved to `/tmp` with a flag;
- `--init-file` is read **after** mariadbd drops to the `mysql` user, so the
  file must live somewhere that user can read — the data directory, not
  `/tmp` written by root.

`db/Satlfile`:

```text
FROM 127.0.0.1:5000/satl-test/freebsd-runtime:15.1
PKG mariadb118-server
COPY db-entrypoint.sh /usr/local/bin/db-entrypoint.sh
RUN chmod +x /usr/local/bin/db-entrypoint.sh
EXPOSE 3306/tcp
ENTRYPOINT ["/usr/local/bin/db-entrypoint.sh"]
```

```console
$ sudo satl build -t 127.0.0.1:5000/satl-test/tuto-db:latest
Built and registered 127.0.0.1:5000/satl-test/tuto-db:latest (manifest sha256:f0fc0018…)
```

`mariadbd --user=mysql` drops privileges itself, so the entrypoint can run as
root — no `sudo`/`su` is needed inside the image (the minimal base has no PAM
stack, so those would not work anyway).

## 4. The stack

The password is a secret, created once:

```console
$ printf 's3cret-tuto' | sudo satl secret create db_password -
1x…
```

`compose.yaml`:

```yaml
services:
  web:
    image: 127.0.0.1:5000/satl-test/tuto-web:latest
    ports:
      - "18090:8080"
    environment:
      DB_HOST: db
    secrets:
      - source: db_password
        target: db_password
    healthcheck:
      test: ["CMD-SHELL", "ip=$$(/sbin/ifconfig | while read a b rest; do [ \"$$a\" = inet ] && { echo \"$$b\"; break; }; done); fetch -qo /dev/null --timeout=2 http://$$ip:8080/health || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 2
    deploy:
      replicas: 3
      placement:
        preferences:
          - spread: node.hostname
  db:
    image: 127.0.0.1:5000/satl-test/tuto-db:latest
    volumes:
      - dbdata:/var/db/mysql
    secrets:
      - source: db_password
        target: db_password
    deploy:
      placement:
        constraints:
          - node.hostname==fbsd-dev---1
volumes:
  dbdata:
secrets:
  db_password:
    external: true
```

What each choice is buying:

- **the secret is mounted on both services** — the app reads it too, and a
  service only gets the secrets it declares (the first deploy of this page's
  app crashed on exactly that);
- **the database is pinned to one node** by the constraint, because its
  volume is node-local — the scheduler warning says as much on deploy;
- **`spread: node.hostname`** keeps the three web replicas on three different
  nodes without forbidding anything (a preference, not a constraint);
- the healthcheck deserves a paragraph:

!!! warning "There is no `localhost` inside a SatL jail"

    A VNET jail's `lo0` carries only `::1` — `127.0.0.1` is unassigned, so the Docker-style `curl http://localhost/` probe cannot connect.
    Probe the task's own address, which is what the `ifconfig` one-liner reads.
    Two more traps the minimal base sets: there is no `awk` (hence the pure-shell `while read`), and compose files refuse `$` interpolation — every literal dollar is written `$$`.

Deploy it with the stack verbs:

```console
$ sudo satl stack deploy -c compose.yaml tuto
network tuto_default created
service tuto_db created
service tuto_web created
$ sudo satl stack ps tuto
ID             NAME         IMAGE                NODE           CURRENT STATE
2ml700oqhqdn   tuto_db.1    …/tuto-db:latest     fbsd-dev---1   Running
26rswhrhoxqs   tuto_web.1   …/tuto-web:latest    fbsd-dev---3   Running
26y2q4xid6iq   tuto_web.2   …/tuto-web:latest    fbsd-dev---1   Running
2s0p6ydq8lu4   tuto_web.3   …/tuto-web:latest    fbsd-dev---2   Running
```

The web tasks took a few seconds to report `Running`: the health gate — a
task is not `RUNNING` until its probe passes, which for this app means "the
database answered `SELECT 1`".

## 5. The mesh, from any node

The port answers on every manager, and round-robins the replicas:

```console
$ for ip in 152.228.230.132 152.228.231.20 152.228.242.228; do
    curl -s -X POST "http://$ip:18090/add?msg=bonjour-de-$ip" -o /dev/null
  done
$ for i in 1 2 3 4 5 6; do curl -s http://152.228.231.20:18090/ |
    grep -o 'réplica: [a-z0-9]*'; done | sort | uniq -c
   2 réplica: 1m4j4qcmrx5s
   2 réplica: 1n1ygnsh1ct6
   2 réplica: 2kneyk0g22a9
```

Every one of those requests went through a node that may host no replica, and all three messages are in the one database on node1.
The `client:` field on the page shows the mesh's relay address, not yours — that is the SNAT trade, and the [`satl.publish.proxy_protocol=v2` label](../use/publishing-ports.md#the-client-address) is the opt-in remedy.

## 6. A rolling update, without losing a request

Change the page, rebuild under a new tag **on each of the three nodes**, and only then update the service.
A rolling update replaces tasks node by node, so a node that never got `:v2` cannot start its replacement — its own loopback registry answers `404` for a tag nothing pushed there, the task fails terminally, and the update stalls on that node.
(A node with *no* registry at all fails differently and much more quietly — [why](../use/images.md#image-locality).)

```console
$ sudo satl build -t 127.0.0.1:5000/satl-test/tuto-web:v2    # on each node
$ sudo satl service update --image 127.0.0.1:5000/satl-test/tuto-web:v2 tuto_web
tuto_web
$ while true; do curl -s -o /dev/null -w "%{http_code} " http://152.228.231.20:18090/; sleep 2; done
200 200 200 200 200 200 200 200 200 200 200 200 …
```

Not one dropped connection: a slot's replacement must pass its healthcheck and outlive the monitor window before the next slot moves, and the published port's pf table follows the live set.
`satl service inspect tuto_web` shows the rollout in `UpdateStatus`.

!!! note "If the update pauses"

    `--update-failure-action pause` (the default) stops a rollout whose tasks fail.
    Push the same update again to resume — and if the failed task still counts against the *same* spec, any small spec change (a label) starts a clean count.
    During this page's run, one task was rejected by a transient `zfs … dataset is busy` and paused the rollout twice before a label bump carried it through.

## 7. A hot resize

```console
$ sudo satl service update --limit-memory 256m tuto_web
tuto_web
$ sudo rctl jail:$(sudo satl service ps tuto_web --no-trunc -q | head -1)
jail:24ceq6bf9xx2dzm0e4bcccwe6:memoryuse:sigkill=268435456
```

The rctl rule changed and the task ids did not — a resources-only update is applied to the live jails, not rolled.
For the database, that is the difference between a resize and an incident.

## 8. The database survives a crash

Kill the jail out from under MariaDB — the honest crash rehearsal, since
`satl kill` on a service task is a retirement (see
[Differences from Docker](../docker-differences.md)):

```console
$ sudo jail -r $(sudo satl service ps tuto_db --no-trunc -q | head -1)
$ sleep 20; sudo satl service ps tuto_db | grep Running
26w02iv5pc0s   tuto_db.1   …/tuto-db:latest   fbsd-dev---1   Running
$ curl -s http://152.228.230.132:18090/ | grep -o 'bonjour-de[^<]*'
bonjour-de-152.228.242.228
bonjour-de-152.228.231.20
bonjour-de-152.228.230.132
```

The replacement task re-ran the entrypoint, found the initialized data
directory on the volume, and every message was still there.

## Where to go next

- [Publishing ports](../use/publishing-ports.md) — the mesh, the SNAT trade,
  and the PROXY-protocol mode;
- [Secrets and configs](../use/secrets-and-configs.md) — rotation is by
  replacement;
- [Rolling updates](../use/rolling-updates.md) — the policy knobs this page
  left at their defaults;
- [Resource limits](../use/resource-limits.md) — what the rctl rules actually
  do, and the shrink warning;
- [Metrics](../use/metrics.md) — watch the whole thing from Prometheus.
