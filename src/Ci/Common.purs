module Ci.Common where

import Prelude
import Ci.Native as N
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core (Json, toObject, toArray, toString, toBoolean)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), maybe)
import Data.String as S
import Data.String.Regex (regex, test)
import Data.String.Regex.Flags (noFlags)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Foreign.Object as O

demand :: String -> Boolean -> Aff Unit
demand message ok = unless ok (throwError (error message))

matches :: String -> String -> Boolean
matches pattern value = either (const false) (flip test value) (regex pattern noFlags)

fromEither :: forall a. Either String a -> Aff a
fromEither = either (throwError <<< error) pure

field :: String -> Json -> Either String Json
field key value = maybe (Left ("Missing JSON field: " <> key)) Right (toObject value >>= O.lookup key)
stringField :: String -> Json -> Either String String
stringField key value = field key value >>= (maybe (Left ("Expected string: " <> key)) Right <<< toString)
boolField :: String -> Json -> Either String Boolean
boolField key value = field key value >>= (maybe (Left ("Expected boolean: " <> key)) Right <<< toBoolean)
jsonArray :: Json -> Either String (Array Json)
jsonArray = maybe (Left "Expected JSON array") Right <<< toArray

-- FluentCI/bsdkrun may print progress before a final typed JSON result.
jsonSuffix :: String -> Either String Json
jsonSuffix output = go (S.split (S.Pattern "\n") (S.trim output))
  where
  go lines = case jsonParser (S.joinWith "\n" lines) of
    Right value -> Right value
    Left _ -> case A.uncons lines of
      Nothing -> Left "No final JSON result"
      Just { tail } -> go tail

readJson :: String -> Aff Json
readJson path = liftEffect (N.readText path) >>= fromEither <<< jsonParser

runWith :: O.Object String -> String -> Array String -> Aff N.Result
runWith env program args = do
  liftEffect $ N.stream ("[ci] $ " <> S.joinWith " " ([ program ] <> args) <> "\n")
  r <- N.command { program, args, env, cwd: "", timeout: 300000, output: N.stream }
  demand (program <> " failed (" <> show r.code <> ")") (r.code == 0)
  pure r

run :: String -> Array String -> Aff N.Result
run = runWith O.empty

required :: String -> Aff String
required key = do
  value <- liftEffect (N.env key)
  demand ("Set " <> key) (value /= "")
  pure value

fallback :: String -> String -> Aff String
fallback key value = do
  found <- liftEffect (N.env key)
  pure (if found == "" then value else found)

projectVersion :: Aff String
projectVersion = readJson "package.json" >>= fromEither <<< stringField "version"

prepareRuntime :: Aff Unit
prepareRuntime = do
  liftEffect do
    let path = ".fluentci/tools/bsdkrun/bin/bsdkrun"
    installed <- N.exists path
    when installed do
      binary <- N.resolve path
      directory <- N.resolve ".fluentci/tools/bsdkrun/bin"
      old <- N.env "PATH"
      N.setEnv "BSDKRUN_BIN" binary
      N.setEnv "PATH" (directory <> ":" <> old)
    N.setEnv "BSDKRUN_NO_AUTO_INSTALL" "1"

bsdkrun :: Aff String
bsdkrun = fallback "BSDKRUN_BIN" "bsdkrun"
