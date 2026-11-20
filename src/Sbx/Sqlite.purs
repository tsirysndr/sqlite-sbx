-- | SQLite has no server of its own, so the sandbox offers two engines over
-- | the data branch, chosen by the version argument:
-- |
-- | - `latest` (the default) or any other tag: the official libSQL server
-- |   image (`sqld`, Turso's SQLite fork) as a container in the shared Docker
-- |   engine. Drizzle Studio and drizzle-kit reach it over HTTP with the
-- |   `turso` dialect; `sqlite3` and `litecli` open the file next to it.
-- | - `turso`: Turso Database, Turso's from-scratch rewrite of SQLite, and
-- |   `sqlite3`: plain SQLite. Both are in-process engines with no network
-- |   server, so the container only holds the branch and the shell
-- |   (`tursodb` or `sqlite3`) and `litecli` open the file; `studio` and
-- |   `drizzle` refuse.
-- |
-- | The CLIs live in a small helper image built in the engine once (the
-- | libsql-server image ships none); in the serverless modes that image is
-- | the container itself. Linux only.
module Sbx.Sqlite (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.Profile (ClientCmd(..), FancyCmd(..), Profile)

-- | The versions that select an in-process engine instead of libSQL server.
turso :: String
turso = "turso"

sqlite3 :: String
sqlite3 = "sqlite3"

serverless :: String -> Boolean
serverless v = v == turso || v == sqlite3

toolsImage :: String
toolsImage = "sqlite-sbx-tools"

dataDir :: String
dataDir = "/var/lib/sqlite"

profile :: Profile
profile =
  { tool: "sqlite-sbx"
  , product: "SQLite"
  , serves: not <<< serverless
  , guestPort: 8080
  , defaultTag: "latest"
  , image: \tag ->
      if serverless tag then toolsImage
      else if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag
      else "ghcr.io/tursodatabase/libsql-server:" <> tag
  , versionNote: ", or an in-process engine with no server (no studio/drizzle): `turso` for Turso Database (its tursodb shell over the file) or `sqlite3` for plain SQLite"
  , linuxOnly: true
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "sqlite" }
  , dataDir: const dataDir
  , rootfsVolume: false
  , rootDisk: const Nothing
  , tools: Just
      { image: toolsImage
      , dockerfile: String.joinWith "\n"
          [ "FROM debian:bookworm-slim"
          , "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils sqlite3 pipx && rm -rf /var/lib/apt/lists/* \\"
          , " && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install litecli \\"
          , " && curl --proto '=https' --tlsv1.2 -LsSf https://github.com/tursodatabase/turso/releases/latest/download/turso_cli-installer.sh | sh \\"
          , " && install -m 755 /root/.turso/tursodb /usr/local/bin/tursodb && rm -rf /root/.turso"
          , ""
          ]
      }
  -- sqld keeps the database under its --db-path: one directory per database
  -- name, on the branch. Harmless for the turso container.
  , env: \c -> Object.fromFoldable [ "SQLD_DB_PATH" /\ (dataDir <> "/" <> c.db), "SQLD_HTTP_LISTEN_ADDR" /\ "0.0.0.0:8080" ]
  -- An in-process engine has nothing to serve: the container idles over the branch.
  , command: \v -> if serverless v then Just [ "sleep", "infinity" ] else Nothing
  , provision: const Nothing
  , ready: \_ v _ -> if serverless v then [ "sh", "-c", "test -d " <> dataDir ] else [ "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080" ]
  , client: Guest \_ v c -> [ if v == turso then "tursodb" else "sqlite3", file v c.db ]
  , clientName: "sqlite3"
  , clientAliases: [ "tursodb" ]
  , fancy: { name: "litecli", cmd: GuestTool \_ v c -> [ "litecli", file v c.db ] }
  , url: \v c port -> if serverless v then "file " <> file v c.db <> " in the container (no server)" else "http://127.0.0.1:" <> show port
  , studioSupported: \_ v -> not (serverless v)
  , dialect: "turso"
  , driver: "@libsql/client"
  , migrations: Nothing
  }

-- | Where the SQLite file is: inside sqld's database directory, or a plain
-- | file for the in-process engines.
file :: String -> String -> String
file v db = if serverless v then dataDir <> "/" <> db <> ".db" else dataDir <> "/" <> db <> "/dbs/default/data"
