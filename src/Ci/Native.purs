-- | Node primitives only. CI decisions and assertions live in PureScript.
module Ci.Native where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign.Object (Object)

type Result = { code :: Int, stdout :: String, stderr :: String }
type Command = { program :: String, args :: Array String, env :: Object String, cwd :: String, timeout :: Int, output :: String -> Effect Unit }
foreign import commandImpl :: Command -> Async Result
command :: Command -> Aff Result
command = toAff <<< commandImpl
foreign import readText :: String -> Effect String
foreign import writeText :: String -> String -> Effect Unit
foreign import appendText :: String -> String -> Effect Unit
foreign import readBytes :: String -> Effect (Array Int)
foreign import copy :: String -> String -> Effect Unit
foreign import remove :: String -> Effect Unit
foreign import mkdir :: String -> Effect Unit
foreign import chmod :: String -> Int -> Effect Unit
foreign import exists :: String -> Effect Boolean
foreign import readableWritable :: String -> Effect Boolean
foreign import resolve :: String -> Effect String
foreign import tempDir :: String -> Effect String
foreign import randomHex :: Int -> Effect String
foreign import sha256 :: String -> Effect String
foreign import env :: String -> Effect String
foreign import setEnv :: String -> String -> Effect Unit
foreign import node :: Effect String
foreign import platform :: Effect { os :: String, arch :: String }
foreign import argv :: Effect (Array String)
foreign import data Port :: Type
foreign import reservePortImpl :: Async { port :: Int, handle :: Port }
reservePort :: Aff { port :: Int, handle :: Port }
reservePort = toAff reservePortImpl
foreign import closePortImpl :: Port -> Async Unit
closePort :: Port -> Aff Unit
closePort = toAff <<< closePortImpl
foreign import onInterrupt :: Effect Unit -> Effect (Effect Unit)
foreign import setArgs :: Array String -> Effect Unit

-- | CI progress goes to stderr so FluentCI stdout capture cannot hide it.
foreign import stream :: String -> Effect Unit
