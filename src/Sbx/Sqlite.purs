-- | SQLite has no server, so the sandbox runs libSQL server (`sqld`, Turso's
-- | SQLite fork) over the data branch: Drizzle Studio and drizzle-kit on the
-- | host reach it over HTTP with the `turso` dialect, and `litecli`/`sqlite3`
-- | open the file inside the guest. The Linux guest is a plain Ubuntu image
-- | provisioned with sqld from libSQL's releases (the official libsql-server
-- | image is Debian 11, whose stale apt sources can install neither litecli
-- | nor the ZFS userland bsdkrun needs for the data branch). On FreeBSD and
-- | NetBSD there is no sqld, so those guests only offer the file and the CLIs.
module Sbx.Sqlite (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Foreign.Object as Object
import Sbx.Profile (ClientCmd(..), FancyCmd(..), Os(..), Profile, shellQuote, withBsdPath)

profile :: Profile
profile =
  { tool: "sqlite-sbx"
  , product: "SQLite (libSQL server)"
  , guestPort: 8080
  , defaultTag: "24.04"
  , image: \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "ubuntu:" <> tag
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "sqlite" }
  , dataDir: case _ of
      Linux -> "/var/lib/sqld"
      FreeBSD -> "/var/db/sqlite"
      NetBSD -> "/var/db/sqlite"
  -- sqld, sqlite3 and litecli are installed onto the rootfs; keep it.
  , rootfsVolume: true
  , env: \_ -> Object.empty
  -- A plain image has nothing to run: boot idle, provisioning starts sqld.
  , command: Just [ "sleep", "infinity" ]
  , provision: case _ of
      Linux -> Just linux
      FreeBSD -> Just (bsd "pkg install -y sqlite3 py311-litecli" "pkg info -e sqlite3 >/dev/null 2>&1" "/usr/local/bin")
      NetBSD -> Just (bsd "pkgin -y install sqlite3 py312-litecli" "pkg_info -qe sqlite3" "/usr/pkg/bin")
  , ready: \os c -> case os of
      Linux -> [ "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080" ]
      _ -> [ "sh", "-c", "test -f " <> shellQuote (bsdFile c.db) ]
  , client: Guest \os c -> withBsdPath ("sqlite3 " <> shellQuote (file os c.db))
  , clientName: "sqlite3"
  , fancy: { name: "litecli", cmd: GuestTool \os c -> withBsdPath ("litecli " <> shellQuote (file os c.db)) }
  , url: \_ port -> "http://127.0.0.1:" <> show port
  , studioSupported: eq Linux
  , dialect: "turso"
  , driver: "@libsql/client"
  , migrations: Nothing
  }

-- | Where the SQLite file is: sqld keeps it inside its database directory.
file :: Os -> String -> String
file os db = case os of
  Linux -> "/var/lib/sqld/" <> db <> "/dbs/default/data"
  _ -> bsdFile db

bsdFile :: String -> String
bsdFile db = "/var/db/sqlite/" <> db <> ".db"

-- | The libSQL server release provisioned into Linux guests.
sqldVersion :: String
sqldVersion = "0.24.32"

linux :: String
linux = String.joinWith "\n"
  [ "set -e"
  , "export DEBIAN_FRONTEND=noninteractive"
  , "if ! command -v sqld >/dev/null 2>&1 || ! command -v litecli >/dev/null 2>&1; then"
  , "  apt-get update -qq >/dev/null"
  , "  apt-get install -y -qq --no-install-recommends ca-certificates curl xz-utils sqlite3 pipx >/dev/null"
  , "  case \"$(uname -m)\" in aarch64|arm64) t=aarch64-unknown-linux-gnu ;; *) t=x86_64-unknown-linux-gnu ;; esac"
  , "  curl -fsSL \"https://github.com/tursodatabase/libsql/releases/download/libsql-server-v" <> sqldVersion <> "/libsql-server-$t.tar.xz\" | tar -xJ -C /tmp"
  , "  install -m 755 \"/tmp/libsql-server-$t/sqld\" /usr/local/bin/sqld"
  , "  PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install litecli >/dev/null"
  , "fi"
  , "mkdir -p \"/var/lib/sqld/$SBX_DB\""
  , "if ! bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080' 2>/dev/null; then"
  , "  cd /var/lib/sqld && nohup sqld --db-path \"/var/lib/sqld/$SBX_DB\" --http-listen-addr 0.0.0.0:8080 >/tmp/sqld.log 2>&1 &"
  , "fi"
  ]

bsd :: String -> String -> String -> String
bsd install installed bin = String.joinWith "\n"
  [ "set -e"
  , "export PATH=" <> bin <> ":$PATH"
  , installed <> " || " <> install <> " >/dev/null"
  , "f=/var/db/sqlite/$SBX_DB.db"
  , "[ -f \"$f\" ] || sqlite3 \"$f\" 'PRAGMA journal_mode=WAL;' >/dev/null"
  ]
