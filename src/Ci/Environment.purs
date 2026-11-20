module Ci.Environment (Variable, decode, persist, exportEnvironment) where

import Prelude
import Ci.Common as C
import Ci.Native as N
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (all)
import Data.String as S
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

type Variable = { name :: String, value :: String }

decode :: String -> Either String (Array Variable)
decode output = do
  json <- C.jsonSuffix output
  entries <- C.field "environment" json >>= C.jsonArray
  if A.null entries then Left "setup-purescript returned an empty environment" else pure unit
  traverse entry entries
  where
  entry json = do
    name <- C.stringField "name" json
    value <- C.stringField "value" json
    if C.matches "^[A-Za-z_][A-Za-z0-9_]*$" name && not (S.contains (S.Pattern "\x0000") value)
      then Right { name, value }
      else Left "Invalid setup environment entry"

persist :: String -> String -> Aff Unit
persist output destination = do
  variables <- C.fromEither (decode output) -- Validate everything before writing.
  marker <- ("fluentci_" <> _) <$> liftEffect (N.randomHex 24)
  C.demand "Environment delimiter collision" (all (\v -> not (S.contains (S.Pattern marker) v.value)) variables)
  liftEffect $ N.appendText destination $ S.joinWith "" $ map (\v -> v.name <> "<<" <> marker <> "\n" <> v.value <> "\n" <> marker <> "\n") variables

exportEnvironment :: String -> Aff Unit
exportEnvironment source = do
  output <- liftEffect (N.readText source)
  destination <- C.required "GITHUB_ENV"
  persist output destination
