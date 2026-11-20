module Main (all, unit, e2e) where

import Prelude
import Data.Either (either)
import Data.Maybe (Maybe, fromMaybe)
import Effect (Effect)
import Effect.Exception (throw)
import FluentCI.Plugin as P

run :: P.Pipeline -> Effect String
run plan = P.stdout plan >>= either (throw <<< P.errorMessage) pure

-- | Install bsdkrun with verified archives and test normal sandbox startup, then run PureScript/Bun unit and live SQLite/libSQL/ZFS tests.
-- | @param directory Project checkout directory; defaults to the current directory.
-- | @param bsdkrunVersion Official bsdkrun release to install; defaults to v0.12.1.
all :: { directory :: Maybe String, bsdkrunVersion :: Maybe String } -> Effect String
all args = run $ P.pipeline "sqlite-sbx-test"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "node", "bin/ci.js", "install", fromMaybe "v0.12.1" args.bsdkrunVersion ]
  # P.exec [ "npm", "test" ]
  # P.exec [ "npm", "run", "build:bin" ]
  # P.exec [ "npm", "run", "test:e2e" ]

-- | Run PureScript unit tests and Bun CLI/CI tests without installing a VM runtime.
-- | @param directory Project checkout directory; defaults to the current directory.
unit :: { directory :: Maybe String } -> Effect String
unit args = run $ P.pipeline "sqlite-sbx-unit"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "npm", "test" ]

-- | Run Bun's real VM, libSQL HTTP port, persistence and ZFS branch tests using an installed bsdkrun.
-- | @param directory Project checkout directory; defaults to the current directory.
e2e :: { directory :: Maybe String } -> Effect String
e2e args = run $ P.pipeline "sqlite-sbx-e2e"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "npm", "run", "test:e2e" ]
