-- | The few host-side things the SDK does not cover: a yes/no prompt, running
-- | a host program on the terminal, and small file helpers.
module Sbx.Native where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Bsdkrun.Types (Bytes)
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toNullable)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign.Object (Object)

-- | Ask on the terminal; true only for an explicit yes.
confirm :: String -> Aff Boolean
confirm question = toAff (confirmImpl question)

foreign import confirmImpl :: String -> Async Boolean

-- | Run a host program with the terminal, extra environment merged over the
-- | current one; yields its exit status.
spawnInherit :: String -> Array String -> Object String -> Aff Int
spawnInherit cmd args env = spawnInheritIn cmd args env Nothing

-- | Same, in a working directory.
spawnInheritIn :: String -> Array String -> Object String -> Maybe String -> Aff Int
spawnInheritIn cmd args env dir = toAff (spawnInheritImpl cmd args env (toNullable dir))

foreign import spawnInheritImpl :: String -> Array String -> Object String -> Nullable String -> Async Int

-- | Run a host program quietly and capture its output.
capture :: String -> Array String -> Aff { stdout :: String, stderr :: String, exitCode :: Int }
capture cmd args = toAff (captureImpl cmd args)

foreign import captureImpl :: String -> Array String -> Async { stdout :: String, stderr :: String, exitCode :: Int }

-- | GET a URL as text.
fetchText :: String -> Aff String
fetchText u = toAff (fetchTextImpl u)

foreign import fetchTextImpl :: String -> Async String

-- | Download a URL to an executable file.
download :: String -> String -> Aff Unit
download u dest = toAff (downloadImpl u dest)

foreign import downloadImpl :: String -> String -> Async Unit

foreign import isTty :: Effect Boolean
foreign import nodeVersion :: Effect String
foreign import nodePath :: Effect String
-- | `$XDG_CONFIG_HOME/<tool>` or `~/.config/<tool>`, created if missing.
foreign import configDir :: String -> Effect String
-- | The installed package's root (where its node_modules live).
foreign import toolRoot :: Effect String
foreign import cwd :: Effect String
foreign import pathJoin :: String -> String -> String
foreign import readJson :: forall a. String -> Effect (Nullable a)
foreign import writeJson :: forall a. String -> a -> Effect Unit
foreign import writeText :: String -> String -> Effect Unit
foreign import removeFile :: String -> Effect Unit
foreign import fileExists :: String -> Effect Boolean
foreign import encodeURIComponent :: String -> String
foreign import writeStdout :: Bytes -> Effect Unit
foreign import writeStderr :: Bytes -> Effect Unit
-- | Absolute path of a program on PATH, if any.
foreign import findExecutable :: String -> Effect (Nullable String)
foreign import homeDir :: Effect String
foreign import mkdirp :: String -> Effect Unit
-- | The host, named the way release assets usually are.
foreign import platform :: Effect { os :: String, arch :: String }
foreign import listDir :: String -> Effect (Array String)

-- | Kill gvproxy processes holding the host port whose bsdkrun is gone;
-- | the pids removed.
foreign import reapOrphanGvproxies :: Int -> Effect (Array Int)

-- | Whether stdout is a terminal that wants colour.
foreign import colorOutput :: Effect Boolean
-- | Wrap text in an SGR code (`"36"` is teal).
foreign import ansi :: String -> String -> String

-- | Hex SHA-256 of a string.
foreign import sha256 :: String -> String
