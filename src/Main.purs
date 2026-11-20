module Main (main) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (runAff_)
import Effect.Console (error)
import Effect.Exception (message)
import Node.Process (setExitCode)
import Sbx.App as App
import Sbx.Cli as Cli
import Sbx.Sqlite (profile)

version :: String
version = "0.1.0"

main :: Effect Unit
main = do
  cmd <- Cli.parseCommand profile version
  runAff_ finish (App.run profile cmd)
  where
  finish = case _ of
    Left err -> error ("error: " <> message err) *> setExitCode 1
    Right code -> setExitCode code
