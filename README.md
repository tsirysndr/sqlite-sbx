# sqlite-sbx

SQLite in a [bsdkrun](https://github.com/tsirysndr/bsdkrun) microVM, with
**branchable data**: the database lives on a ZFS branch you fork copy-on-write,
switch between, and throw away, like `git branch` for your database. Since
SQLite has no server, the sandbox runs [libSQL
server](https://github.com/tursodatabase/libsql) (`sqld`, Turso's SQLite fork)
over the branch, so Drizzle Studio and drizzle-kit on the host reach it over
HTTP, while `sqlite3` and [litecli](https://litecli.com) open the file next to
it. On Linux that is the official `libsql-server` image as a container in
bsdkrun's shared Docker engine VM.

```sh
sqlite-sbx start                   # sqld in a container, port 8080 on 127.0.0.1
sqlite-sbx checkout -b feature     # fork the data, mount the fork
sqlite-sbx drizzle push            # try a schema change on it
sqlite-sbx studio                  # look at it in Drizzle Studio
sqlite-sbx checkout main           # back to the untouched data
sqlite-sbx branch -d feature       # done with it
```

One sandbox per tool: a VM named `sqlite-sbx`, a ZFS volume named `sqlite-sbx`
(the data), a plain volume `sqlite-sbx-rootfs` (what provisioning installs),
and a small state file under `~/.config/sqlite-sbx`. Studio and drizzle-kit run
on the host and talk to sqld over a forwarded port; the file-based tools run in
the guest.

Written in PureScript on the [bsdkrun PureScript
SDK](https://github.com/tsirysndr/bsdkrun-purescript). Siblings:
[postgres-sbx](../postgres-sbx) and [mariadb-sbx](../mariadb-sbx) share the
same code and commands.

## Requirements

| What | Why |
| --- | --- |
| [bsdkrun](https://github.com/tsirysndr/bsdkrun#install) 0.12 or newer | runs the VM and the ZFS volume (`brew install tsirysndr/tap/bsdkrun`) |
| macOS on Apple Silicon, or Linux with KVM | what bsdkrun supports |
| Node.js 22 or newer | runs the tool, drizzle-kit and Studio |

`sqlite-sbx doctor` checks all of it.

## Install

From a checkout, with the
[bsdkrun-purescript](https://github.com/tsirysndr/bsdkrun-purescript) SDK next
to it (see `spago.yaml` to point at the git repository instead):

```sh
npm install        # also builds (spago)
npm link           # puts `sqlite-sbx` on your PATH
sqlite-sbx doctor
```

### Single binary

```sh
npm run build:bin  # needs bun; writes dist/sqlite-sbx
```

The binary bundles the tool, the SDK and the `@libsql/client` driver.
drizzle-kit cannot be bundled (it ships esbuild's native binary and runs as its
own process), so `studio` and `drizzle` look for a `drizzle-kit` on PATH when
run from the binary: `npm i -g drizzle-kit drizzle-orm @libsql/client`.

## Commands

```
start      Start the sandbox, creating the VM and its data volume on first run
stop       Stop the VM (data stays on its branch)
status     Show the VM, the mounted branch and the connection URL
ssh        Open a shell in the VM (alias: shell)
log        Show the VM console log, -f to follow (alias: logs)
branch     List data branches, create one (copy-on-write) or delete one
checkout   Switch the data directory to BRANCH, -b to create it first (alias: switch)
sqlite3    Open sqlite3 on the database file, inside the VM
litecli    Open litecli (auto-completion, syntax highlighting) on it, inside the VM
url        Print the connection URL
studio     Open Drizzle Studio on the sandbox database
drizzle    Run drizzle-kit with DATABASE_URL pointing at the sandbox
doctor     Check bsdkrun, the hypervisor, Node, drizzle-kit and litecli
destroy    Remove the VM and the data volume with every branch (asks first)
```

Every command has `--help`.

## Starting

```sh
sqlite-sbx start                                # linux, ghcr.io/tursodatabase/libsql-server:latest
sqlite-sbx start linux 0.24.33                  # any tag of that image, or a full image reference
sqlite-sbx start --db app                       # names the database (default: sqlite)
sqlite-sbx start freebsd 15.1                   # sqlite3 + litecli from pkg; no server
sqlite-sbx start netbsd                         # sqlite3 + litecli from pkgsrc; no server
```

| Option | Default | |
| --- | --- | --- |
| `--port, -p PORT` | 8080 | host port forwarded to sqld's HTTP port; change it on a later start (the VM is recreated, the data stays) |
| `--db NAME` | sqlite | database name: `/var/lib/sqld/NAME` on Linux, `/var/db/sqlite/NAME.db` on BSD |
| `--cpus N` | 2 | changeable on a later start |
| `--mem MIB` | 1024 | changeable on a later start |
| `--branch, -b BRANCH` | the current one | data branch to mount |
| `--size SIZE` | 10G | data volume size when it is created (sparse) |

There are no credentials: sqld runs without authentication and is reachable
only through the published port on 127.0.0.1.

**Linux.** The server is a container in bsdkrun's shared Docker engine VM
(`bsdkrun-docker`), not a VM of its own: one VM serves every Linux sandbox on
the host. `start` creates the engine the first time, attaches the data volume
to it (a new disk needs the engine restarted once; its other containers come
back by themselves), and runs the official `libsql-server` image with the
branch bind-mounted at `/var/lib/sqld` and sqld pointed at `NAME` under it.
That image ships no CLIs, so `sqlite3` and `litecli` run in a small helper
image (`sqlite-sbx-tools`, Alpine with both) built in the engine the first
time and started with the same branch mounted. `--cpus` and `--mem` size a
BSD VM and are not applied to the container.

**FreeBSD and NetBSD.** No sqld package exists, so these guests only provide
the file (`/var/db/sqlite/NAME.db`, created with WAL journaling) and the
in-guest CLIs. `studio` and `drizzle` refuse there. These guests are scripted
but have had less exercise than Linux.

## Branches

The database lives on a ZFS branch inside the sandbox's volume. Branches are
ZFS clones: forking is instant and costs nothing until the branches diverge.

```sh
sqlite-sbx branch                   # list; * marks the mounted one (also: branch ls)
sqlite-sbx branch staging           # fork the current branch (no switch)
sqlite-sbx branch hotfix --from main
sqlite-sbx checkout staging         # stop, remount, start
sqlite-sbx checkout -b try-this     # fork and switch in one go
sqlite-sbx branch -d try-this       # delete (also: branch rm NAME); not main, not the mounted one
```

`checkout` restarts the VM on the other branch, so connections drop. Forking
while the VM is stopped boots a short-lived FreeBSD helper to do it (about 15
seconds).

## Drizzle Studio and drizzle-kit

Both run on the host, from this package's `node_modules`, and reach sqld with
the `turso` dialect over `http://127.0.0.1:8080`.

```sh
sqlite-sbx studio                   # https://local.drizzle.studio, server on 127.0.0.1:4983
sqlite-sbx drizzle push             # drizzle-kit push against the sandbox
sqlite-sbx drizzle generate
sqlite-sbx drizzle migrate
```

`drizzle` runs drizzle-kit in the current directory with `DATABASE_URL` set to
the sandbox, so a project's `drizzle.config.ts` can read
`process.env.DATABASE_URL` (dialect `turso`, `dbCredentials: { url }`). If the
directory has no drizzle config, one that points at the sandbox is supplied
(`~/.config/sqlite-sbx/drizzle.config.ts`).

From code, `@libsql/client` connects the same way:

```js
import { createClient } from "@libsql/client";
const db = createClient({ url: "http://127.0.0.1:8080" });
```

## Clients

```sh
sqlite-sbx sqlite3                  # sqlite3 on the file, inside the VM
sqlite-sbx litecli                  # litecli on the file, inside the VM
sqlite-sbx url                      # http://127.0.0.1:8080
sqlite-sbx ssh                      # a shell in the VM, or in the sqld container on Linux
```

sqld keeps the database at `/var/lib/sqld/NAME/dbs/default/data` in WAL mode;
the CLIs open that file while sqld is running, which SQLite's locking handles.
Prefer Studio or the HTTP client for writes while the server is up.

## Where things live

| | |
| --- | --- |
| `~/.config/sqlite-sbx/state.json` | OS, version, port, database, branch, resources |
| `~/.config/sqlite-sbx/drizzle.config.ts` | written by `studio` / `drizzle` |
| `bsdkrun ps -a`, `bsdkrun zfs ls sqlite-sbx`, `bsdkrun docker ps` | the VM or the container, and the data volume |
| `/mnt/sqlite-sbx-BRANCH` in the engine, `/var/lib/sqld` in the container (Linux); `/var/db/sqlite` (BSD) | the branch's mountpoint |

`sqlite-sbx destroy` removes all of it after confirmation (`--yes` to skip).

## Troubleshooting

- `sqlite-sbx doctor` — bsdkrun, the hypervisor, Node, drizzle-kit.
- `sqlite-sbx log -f` — the guest console; `log --boot` for bsdkrun's own boot log when a VM dies early.
- `sqlite-sbx status` — whether sqld accepts connections on the forwarded port.
- sqld's own log is `/tmp/sqld.log` in the guest (`sqlite-sbx ssh`).
- A VM named `sqlite-sbx` that the tool did not create: `bsdkrun rm -f sqlite-sbx`.

## Development

```sh
npm install
npm test            # unit tests (profile, argv)
npm run build
node bin/sqlite-sbx.js --help
```

`src/Sbx/Sqlite.purs` is the SQLite profile: image, port, data directory,
provisioning scripts (sqld, sqlite3, litecli), readiness probe, clients,
drizzle dialect. `Sbx.App`, `Sbx.Cli`, `Sbx.Native`, `Sbx.State` and
`Sbx.Profile` are shared verbatim with postgres-sbx and mariadb-sbx.

MIT license.
