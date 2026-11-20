module Test.Main where

import Prelude
import Bsdkrun.Options as Options
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Sbx.Sqlite (profile)
import Sbx.Profile (Os(..))

main :: Effect Unit
main = do
  let c = profile.defaults
  unless (profile.url c 8080 == "http://127.0.0.1:8080") $ throw "url"
  unless (profile.image "latest" == "ghcr.io/tursodatabase/libsql-server:latest" && profile.image "debian:bookworm" == "debian:bookworm") $ throw "image"
  unless (profile.dataDir Linux == "/var/lib/sqld" && profile.studioSupported Linux && not (profile.studioSupported FreeBSD)) $ throw "linux only studio"
  let args = Options.buildCreateArgs (Options.freebsd # Options.withDiskSize "8G" # Options.withZfs [ "sqlite-sbx@main:/var/db/sqlite" ])
  unless (args == [ "freebsd", "-d", "--zfs", "sqlite-sbx@main:/var/db/sqlite", "--disk-size", "8G" ]) $ throw ("zfs args: " <> show args)
  log "sqlite-sbx tests passed"
