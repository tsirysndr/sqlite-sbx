module Ci.Main (main) where

import Prelude
import Ci.Common as C
import Ci.E2E as E2E
import Ci.Environment as Environment
import Ci.Install as Install
import Ci.Native as N
import Ci.Release as Release
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff, runAff_, forkAff, joinFiber, finally, launchAff_, killFiber)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (message, error)
import Node.Process (setExitCode)

main :: Effect Unit
main = runAff_ finish do
  args <- liftEffect N.argv
  fiber <- forkAff (dispatch args)
  removeHandler <- liftEffect $ N.onInterrupt (launchAff_ (killFiber (error "CI run interrupted") fiber))
  finally (liftEffect removeHandler) (joinFiber fiber)
  where
  finish (Left err) = Console.error (message err) *> setExitCode 1
  finish (Right _) = pure unit

dispatch :: Array String -> Aff Unit
dispatch = case _ of
  [ "e2e" ] -> E2E.run
  args | A.take 1 args == [ "sandbox-cli" ] -> case A.uncons (A.drop 1 args) of
    Just { head: name, tail } -> E2E.sandboxCli name tail
    Nothing -> C.demand "Missing sandbox name" false
  [ "install", version ] -> Install.install version
  [ "build-binary" ] -> Release.buildBinary
  [ "release" ] -> Release.build
  [ "publish" ] -> Release.publish
  [ "export-env", path ] -> Environment.exportEnvironment path
  _ -> C.demand "Usage: ci install VERSION | build-binary | release | publish | export-env FILE" false
