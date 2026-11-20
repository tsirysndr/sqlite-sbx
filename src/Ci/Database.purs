-- | Host database driver primitives; E2E assertions live in Ci.E2E.
module Ci.Database (query) where
import Prelude
import Bsdkrun.Internal (Async, toAff)
import Effect.Aff (Aff)
foreign import queryImpl :: { url :: String, sql :: String } -> Async (Array (Array String))
query :: { url :: String, sql :: String } -> Aff (Array (Array String))
query = toAff <<< queryImpl
