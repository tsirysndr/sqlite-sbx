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
  unless (profile.image "24.04" == "ubuntu:24.04" && profile.image "debian:bookworm" == "debian:bookworm") $ throw "image"
  unless (profile.dataDir Linux == "/var/lib/sqld" && profile.studioSupported Linux && not (profile.studioSupported FreeBSD)) $ throw "linux only studio"
  let args = Options.buildCreateArgs (Options.linux (profile.image "24.04") # Options.withVolume "sqlite-sbx-rootfs" # Options.withCommand [ "sleep", "infinity" ] # Options.withZfs [ "sqlite-sbx@main:/var/lib/sqld" ])
  unless (args == [ "linux", "ubuntu:24.04", "-d", "-v", "sqlite-sbx-rootfs", "--zfs", "sqlite-sbx@main:/var/lib/sqld", "--", "sleep", "infinity" ]) $ throw ("zfs args: " <> show args)
  log "sqlite-sbx tests passed"
