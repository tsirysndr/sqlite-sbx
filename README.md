# sqlite-sbx

SQLite in a [bsdkrun](https://github.com/tsirysndr/bsdkrun) microVM, with
**branchable data**: the database lives on a ZFS branch you fork copy-on-write,
switch between, and throw away, like `git branch` for your database. It runs
as a container in bsdkrun's shared Docker engine VM, with a choice of engine:
[libSQL server](https://github.com/tursodatabase/libsql) (`sqld`, Turso's
SQLite fork, the default), so Drizzle Studio and drizzle-kit on the host reach
it over HTTP; [Turso Database](https://github.com/tursodatabase/turso),
Turso's rewrite of SQLite, through its `tursodb` shell; or plain `sqlite3`.
[litecli](https://litecli.com) opens the file in every case. Linux guests only.

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
| [bsdkrun](https://github.com/tsirysndr/bsdkrun#install) 0.12.1 or newer | runs the VM and the ZFS volume (`brew install tsirysndr/tap/bsdkrun`) |
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
sqlite-sbx start                                # libSQL server, ghcr.io/tursodatabase/libsql-server:latest
sqlite-sbx start linux 0.24.33                  # any tag of that image, or a full image reference
sqlite-sbx start linux turso                    # Turso Database: tursodb over the file, no server
sqlite-sbx start linux sqlite3                  # plain SQLite: sqlite3 over the file, no server
sqlite-sbx start --db app                       # names the database (default: sqlite)
```

| Option | Default | |
| --- | --- | --- |
| `--port, -p PORT` | 8080 | host port published for sqld's HTTP port; change it on a later start (the container is recreated, the data stays) |
| `--db NAME` | sqlite | database name: `/var/lib/sqlite/NAME` (sqld) or `/var/lib/sqlite/NAME.db` (turso, sqlite3) |
| `--cpus N` | 2 | changeable on a later start |
| `--mem MIB` | 1024 | changeable on a later start |
| `--branch, -b BRANCH` | the current one | data branch to mount |
| `--size SIZE` | 10G | data volume size when it is created (sparse) |

There are no credentials: sqld runs without authentication and is reachable
only through the published port on 127.0.0.1.

**The engine VM.** The sandbox is a container in bsdkrun's shared Docker
engine VM (`bsdkrun-docker`), not a VM of its own: one VM serves every Linux
sandbox on the host. `start` creates the engine the first time, attaches the
data volume to it (a new disk needs the engine restarted once; its other
containers come back by themselves), and runs the container with the branch
bind-mounted at `/var/lib/sqlite`. The engine is chosen by the version
argument and fixed for the life of the sandbox (`destroy` to change it):

- a tag (default `latest`): the official `libsql-server` image, sqld pointed
  at `NAME` under the mount, its HTTP port published on 127.0.0.1;
- `turso` or `sqlite3`: in-process engines with nothing to serve, so the
  container just idles over the branch and the shells open the file.
  `studio` and `drizzle` refuse, `url` names the file.

The CLIs (`sqlite3`, `tursodb`, `litecli`) live in a small helper image,
`sqlite-sbx-tools`, built in the engine the first time from an inline
Dockerfile (Debian, with Turso's installer for `tursodb`); the server-less
engines run that image as the container itself. `--cpus` and `--mem` are not
applied to the container. There are no BSD guests: unlike the PostgreSQL and
MariaDB sandboxes, this one is Linux only.

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

`checkout` recreates the container on the other branch, so connections drop.
Forking while the engine VM is stopped boots a short-lived FreeBSD helper to
do it (about 15 seconds).

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
sqlite-sbx sqlite3                  # the shell on the file (tursodb for the turso engine; alias: tursodb)
sqlite-sbx litecli                  # litecli on the file
sqlite-sbx url                      # http://127.0.0.1:8080, or the file for the server-less engines
sqlite-sbx ssh                      # a shell in the container
sqlite-sbx exec sh -c 'ls /var/lib/sqlite'   # any command in it, stdin/stdout/stderr bound
```

sqld keeps the database at `/var/lib/sqlite/NAME/dbs/default/data` in WAL
mode; the CLIs open that file while sqld is running, which SQLite's locking
handles. Prefer Studio or the HTTP client for writes while the server is up.

## Where things live

| | |
| --- | --- |
| `~/.config/sqlite-sbx/state.json` | OS, version, port, database, branch, resources |
| `~/.config/sqlite-sbx/drizzle.config.ts` | written by `studio` / `drizzle` |
| `bsdkrun docker ps`, `bsdkrun zfs ls sqlite-sbx` | the container and the data volume |
| `/mnt/sqlite-sbx-BRANCH` in the engine VM, `/var/lib/sqlite` in the container | the branch's mountpoint |

`sqlite-sbx destroy` removes all of it after confirmation (`--yes` to skip).

## Troubleshooting

- `sqlite-sbx doctor` — bsdkrun, the hypervisor, Node, drizzle-kit.
- `sqlite-sbx log -f` — the container's log; `log --boot` for the engine VM's boot log.
- `sqlite-sbx status` — whether sqld accepts connections on the published port.
- A VM named `sqlite-sbx` from an older version that gave Linux its own VM: `sqlite-sbx destroy`, then start again.

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

## CI and releases

Local test commands require Bun in addition to Node.js and the PureScript tools.

GitHub Actions runs PureScript unit tests, Bun CI checks, and live Linux
sandbox tests on Ubuntu with KVM through the custom `.fluentci/test` module.
The live suite connects with the host database driver, checks port forwarding,
ZFS branch isolation, data persistence across restarts, and cleanup. Command
output streams continuously, with a heartbeat for long operations; diagnostics
are uploaded even on failure. Live tests require KVM and are never skipped.

```sh
npm ci
npm test
npm run build:bin
npm run test:e2e                # installed bsdkrun >= 0.12.1 and Docker CLI
fluentci run test unit          # FluentCI 0.17.8
fluentci run --workflow test    # Ubuntu x86_64, sudo and /dev/kvm; installs bsdkrun
```

The workflows use `setup-fluentci@next` with a pinned CLI and the locked
`setup-purescript@v0.2.0` module for PureScript, Spago, Node and Bun. CI
orchestration, installation checks, release validation and cleanup live in
`src/Ci` as PureScript; Node FFI supplies process, filesystem and driver calls.

Pushing a version tag such as `v0.1.0` triggers release tests, then builds
standalone binaries for macOS ARM64, Linux x86_64 and Linux ARM64. The release
job verifies the tag against `package.json` and the embedded CLI version,
checks executable architectures, and uploads three `.tar.gz` archives and
`SHA256SUMS` to GitHub Releases. The Release workflow can also be dispatched
manually with an existing matching tag. Publishing uses the workflow's
`GITHUB_TOKEN`; no additional repository secret is required.
