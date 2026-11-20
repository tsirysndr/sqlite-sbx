-- | What the tool remembers between invocations: how the sandbox was created.
-- | Kept as JSON under `$XDG_CONFIG_HOME/<tool>` (`~/.config/<tool>`). The
-- | machine and the volume themselves are bsdkrun's; this only records the
-- | choices that bsdkrun does not report back (credentials, OS, version).
module Sbx.State where

import Prelude
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Sbx.Native as Native

type State =
  { os :: String
  , version :: String -- ^ Linux image tag or BSD release; "" for the default
  , port :: Int
  , user :: String
  , password :: String
  , db :: String
  , branch :: String
  , cpus :: Int
  , mem :: Int
  }

path :: String -> Effect String
path tool = Native.configDir tool <#> \dir -> Native.pathJoin dir "state.json"

load :: String -> Effect (Maybe State)
load tool = path tool >>= Native.readJson <#> toMaybe'
  where
  toMaybe' :: Nullable State -> Maybe State
  toMaybe' = toMaybe

save :: String -> State -> Effect Unit
save tool st = path tool >>= \p -> Native.writeJson p st

clear :: String -> Effect Unit
clear tool = path tool >>= Native.removeFile
