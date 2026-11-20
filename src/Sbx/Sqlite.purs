-- | SQLite has no server, so the sandbox runs libSQL server (`sqld`, Turso's
-- | SQLite fork) over the data branch: Drizzle Studio and drizzle-kit on the
-- | host reach it over HTTP with the `turso` dialect, and `litecli`/`sqlite3`
-- | open the file. On Linux that is the official libsql-server image as a
-- | container in the shared Docker engine, with the CLIs in a small helper
-- | image built once in the engine (the server image has none). On FreeBSD
-- | and NetBSD there is no sqld, so those guests only offer the file and the
-- | CLIs.
module Sbx.Sqlite (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.Profile (ClientCmd(..), FancyCmd(..), Os(..), Profile, shellQuote, withBsdPath)

profile :: Profile
profile =
  { tool: "sqlite-sbx"
  , product: "SQLite (libSQL server)"
  , guestPort: 8080
  , defaultTag: "latest"
  , image: \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "ghcr.io/tursodatabase/libsql-server:" <> tag
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "sqlite" }
  , dataDir: case _ of
      Linux -> "/var/lib/sqld"
      FreeBSD -> "/var/db/sqlite"
      NetBSD -> "/var/db/sqlite"
  , rootfsVolume: false
  -- Room for sqlite3 and litecli (python) on a BSD root disk.
  , rootDisk: case _ of
      Linux -> Nothing
      _ -> Just "8G"
  , tools: Just
      { image: "sqlite-sbx-tools"
      , dockerfile: String.joinWith "\n"
          [ "FROM alpine:3.21"
          , "RUN apk add --no-cache sqlite py3-pip && pip install --no-cache-dir --break-system-packages litecli"
          , ""
          ]
      }
  -- sqld keeps the database under its --db-path: one directory per database
  -- name, on the branch.
  , env: \c -> Object.fromFoldable [ "SQLD_DB_PATH" /\ ("/var/lib/sqld/" <> c.db), "SQLD_HTTP_LISTEN_ADDR" /\ "0.0.0.0:8080" ]
  , command: Nothing
  , provision: case _ of
      Linux -> Nothing
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

bsd :: String -> String -> String -> String
bsd install installed bin = String.joinWith "\n"
  [ "set -e"
  , "export PATH=" <> bin <> ":$PATH"
  , installed <> " || " <> install <> " >/dev/null"
  , "f=/var/db/sqlite/$SBX_DB.db"
  , "[ -f \"$f\" ] || sqlite3 \"$f\" 'PRAGMA journal_mode=WAL;' >/dev/null"
  ]
