-- | Host primitives for locking branch metadata and talking to gvproxy.
module Sbx.ParallelNative where
import Prelude
import Bsdkrun.Internal (Async, toAff)
import Effect (Effect)
import Effect.Aff (Aff)
foreign import lock :: String -> Effect Unit
foreign import unlock :: String -> Effect Unit
foreign import forwardImpl :: { stateDir :: String, ip :: String, port :: Int, guestPort :: Int, enabled :: Boolean } -> Async Unit
forward :: { stateDir :: String, ip :: String, port :: Int, guestPort :: Int, enabled :: Boolean } -> Aff Unit
forward = toAff <<< forwardImpl

foreign import sha256 :: String -> String

foreign import writeJson :: forall a. String -> a -> Effect Unit
