module Test.Main where

import Prelude
import Bsdkrun.Options as Options
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Sbx.Sqlite (profile)
import Data.Maybe (Maybe(..))
import Sbx.Profile (Os(..))

main :: Effect Unit
main = do
  let c = profile.defaults
  unless (profile.url "latest" c 8080 == "http://127.0.0.1:8080") $ throw "url"
  unless (profile.image "latest" == "ghcr.io/tursodatabase/libsql-server:latest" && profile.image "debian:bookworm" == "debian:bookworm" && profile.image "turso" == "sqlite-sbx-tools") $ throw "image"
  unless (profile.command "turso" == Just [ "sleep", "infinity" ] && profile.command "sqlite3" == Just [ "sleep", "infinity" ] && profile.command "latest" == Nothing && profile.linuxOnly && not (profile.studioSupported Linux "turso") && profile.studioSupported Linux "latest") $ throw "serverless variants"
  unless (profile.image "sqlite3" == "sqlite-sbx-tools") $ throw "sqlite3 image"
  unless (profile.dataDir Linux == "/var/lib/sqlite" && profile.studioSupported Linux "latest" && not (profile.studioSupported Linux "sqlite3")) $ throw "serverless engines have no studio"
  log "sqlite-sbx tests passed"
