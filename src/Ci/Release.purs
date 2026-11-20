module Ci.Release (Target, targets, verifyVersion, verifyBinary, build, publish, buildBinary) where

import Prelude
import Ci.Common as C
import Ci.Native as N
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

type Target = { platform :: String, bun :: String, os :: String, arch :: String }
targets :: Array Target
targets =
  [ { platform: "darwin-aarch64", bun: "bun-darwin-arm64", os: "darwin", arch: "arm64" }
  , { platform: "linux-x86_64", bun: "bun-linux-x64-baseline", os: "linux", arch: "x64" }
  , { platform: "linux-arm64", bun: "bun-linux-arm64", os: "linux", arch: "arm64" }
  ]

verifyVersion :: String -> String -> String -> Either String Unit
verifyVersion tag version cli
  | not (C.matches "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$" tag) || tag /= "v" <> version = Left ("Release tag must match package.json: v" <> version)
  | S.trim cli /= "sqlite-sbx " <> version = Left "Main.version and package.json disagree"
  | otherwise = Right unit

verifyBinary :: Array Int -> String -> Either String Unit
verifyBinary bytes platform =
  if A.length bytes < 32 then Left "Truncated executable"
  else if platform == "darwin-aarch64" then check (A.take 8 bytes == [207,250,237,254,12,0,0,1])
  else if platform == "linux-x86_64" then elf 62
  else if platform == "linux-arm64" then elf 183
  else Left "Unknown release platform"
  where
  check ok = if ok then Right unit else Left ("Executable architecture mismatch for " <> platform)
  elf machine = check (A.take 6 bytes == [127,69,76,70,2,1] && A.slice 18 20 bytes == [machine,0])

buildBinary :: Aff Unit
buildBinary = do
  liftEffect (N.mkdir "dist")
  void $ C.run "bun" [ "build", "--compile", "--minify", "bin/sqlite-sbx.js", "--outfile", "dist/sqlite-sbx" ]

build :: Aff Unit
build = do
  platform <- C.required "RELEASE_PLATFORM"
  target <- C.fromEither case A.find (\t -> t.platform == platform) targets of
    Just found -> Right found
    Nothing -> Left "Set RELEASE_PLATFORM to darwin-aarch64, linux-x86_64 or linux-arm64"
  supplied <- liftEffect (N.env "BUN_TARGET")
  C.demand "BUN_TARGET does not match RELEASE_PLATFORM" (supplied == "" || supplied == target.bun)
  tag <- C.required "RELEASE_TAG"
  version <- C.projectVersion
  node <- liftEffect N.node
  cli <- C.run node [ "bin/sqlite-sbx.js", "--version" ]
  C.fromEither (verifyVersion tag version cli.stdout)
  staging <- liftEffect (N.resolve ("dist/release-build/" <> platform))
  liftEffect (N.mkdir staging *> N.mkdir "dist/release")
  let executable = staging <> "/sqlite-sbx"
  void $ C.run "bun" [ "build", "--compile", "--minify", "--target", target.bun, "bin/sqlite-sbx.js", "--outfile", executable ]
  liftEffect (N.chmod executable 493)
  liftEffect (N.readBytes executable) >>= \bytes -> C.fromEither (verifyBinary bytes platform)
  host <- liftEffect N.platform
  when (host.os == target.os && host.arch == target.arch) do
    result <- C.run executable [ "--version" ]
    C.fromEither (verifyVersion tag version result.stdout)
  liftEffect $ for_ [ "README.md", "LICENSE" ] \file -> N.copy file (staging <> "/" <> file)
  archive <- liftEffect (N.resolve ("dist/release/sqlite-sbx-" <> platform <> ".tar.gz"))
  void $ C.run "tar" [ "-czf", archive, "-C", staging, "sqlite-sbx", "README.md", "LICENSE" ]

-- Only invoked by the contents:write publish job, never by tests or builds.
publish :: Aff Unit
publish = do
  tag <- C.required "RELEASE_TAG"
  version <- C.projectVersion
  C.fromEither (verifyVersion tag version ("sqlite-sbx " <> version))
  let assets = map (\t -> "release-assets/sqlite-sbx-" <> t.platform <> ".tar.gz") targets
  checksums <- traverse (\path -> do
    liftEffect (N.exists path) >>= C.demand ("Missing release asset: " <> path)
    hash <- liftEffect (N.sha256 path)
    pure (hash <> "  " <> S.drop (S.length "release-assets/") path <> "\n")) assets
  liftEffect $ N.writeText "release-assets/SHA256SUMS" (S.joinWith "" checksums)
  existing <- N.command { program: "gh", args: [ "release", "view", tag ], env: mempty, cwd: "", timeout: 30000, output: const (pure unit) }
  when (existing.code /= 0) $ void $ C.run "gh" [ "release", "create", tag, "--verify-tag", "--generate-notes", "--title", tag ]
  void $ C.run "gh" ([ "release", "upload", tag ] <> assets <> [ "release-assets/SHA256SUMS", "--clobber" ])
