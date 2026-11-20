-- | A runtime has its own name and state; all instances share the parent pool.
module Sbx.Identity (volumeName, instanceName, isInstance, validName) where
import Prelude
import Data.Array as A
import Data.Maybe (fromMaybe, isJust)
import Data.String as S
import Data.String.CodeUnits as CU
import Sbx.ParallelNative as N

volumeName :: String -> String
volumeName tool = fromMaybe tool (A.head (S.split (S.Pattern ".branch-") tool))
isInstance :: String -> Boolean
isInstance tool = volumeName tool /= tool
instanceName :: String -> String -> String
instanceName tool branch = volumeName tool <> ".branch-" <> S.take 20 (N.sha256 branch)
validName :: String -> Boolean
validName name = S.length name > 0 && S.length name <= 64
  && not (startsWith (S.Pattern "-") name || startsWith (S.Pattern ".") name)
  && A.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || A.elem c ['-', '_', '.']) (CU.toCharArray name)
  && not (A.elem name ["main", "ls", "list", "rm", "delete", "mirror", "raidz", "raidz1", "raidz2", "raidz3", "spare", "log", "cache", "draid"] || startsWith (S.Pattern "c0") name)

startsWith :: S.Pattern -> String -> Boolean
startsWith prefix = isJust <<< S.stripPrefix prefix
