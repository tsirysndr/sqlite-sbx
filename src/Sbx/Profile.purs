-- | What distinguishes one database sandbox from another: image, ports,
-- | credentials, data directory, how to provision it on a BSD guest, and how
-- | to tell when it is ready. `Sbx.App` is written against this record.
module Sbx.Profile where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Foreign.Object (Object)

data Os = Linux | FreeBSD | NetBSD

derive instance Eq Os

osName :: Os -> String
osName = case _ of
  Linux -> "linux"
  FreeBSD -> "freebsd"
  NetBSD -> "netbsd"

parseOs :: String -> Maybe Os
parseOs s = case String.toLower s of
  "linux" -> Just Linux
  "freebsd" -> Just FreeBSD
  "netbsd" -> Just NetBSD
  _ -> Nothing

type Creds = { user :: String, password :: String, db :: String }

-- | How the interactive client runs: with a PTY inside the guest, or as a
-- | host program (`node` script under the package root, given the host port).
data ClientCmd
  = Guest (Os -> Creds -> Array String)
  | Host (Int -> Creds -> Array String)

-- | The friendlier CLI (pgcli, mycli, litecli): run on the host through
-- | `uvx`/`pipx run` with these arguments (the first is the package), or
-- | with a PTY inside the guest.
data FancyCmd
  = HostTool (Creds -> Int -> Array String)
  | GuestTool (Os -> Creds -> Array String)

-- | A schema-migration tool that runs on the host against the sandbox
-- | (pgroll for PostgreSQL): how to install it and how to point it at the
-- | database.
type Migrations =
  { name :: String -- ^ the executable
  , brew :: String -- ^ Homebrew formula
  , repo :: String -- ^ GitHub repository with release binaries
  , asset :: { os :: String, arch :: String } -> String -- ^ release asset for a host ("macos"/"linux", "arm64"/"amd64")
  , urlFlag :: String -- ^ flag that takes the database URL
  , envVar :: String -- ^ environment variable that takes it too
  , url :: Creds -> Int -> String -- ^ the URL the tool wants
  , dir :: String -- ^ default migrations directory
  }

type Profile =
  { tool :: String -- ^ the command name; also the machine and volume name
  , product :: String -- ^ "PostgreSQL"
  , guestPort :: Int -- ^ the port the server listens on inside the guest
  , defaultTag :: String -- ^ Linux image tag when none is given
  , image :: String -> String -- ^ Linux image for a tag (or a full reference)
  , hasCredentials :: Boolean -- ^ whether --user/--password mean anything
  , defaults :: Creds
  , dataDir :: Os -> String -- ^ where the ZFS branch is mounted (the data directory lives in it)
  , rootfsVolume :: Boolean -- ^ keep the Linux rootfs on a named volume, so what provisioning installs survives restarts
  , env :: Creds -> Object String -- ^ the Linux image's environment
  , command :: Maybe (Array String) -- ^ override the Linux image's command
  , provision :: Os -> Maybe String -- ^ setup script run as root on every start; reads SBX_USER, SBX_PASSWORD, SBX_DB
  , ready :: Os -> Creds -> Array String -- ^ exits 0 once the server accepts TCP connections
  , client :: ClientCmd -- ^ the interactive client
  , clientName :: String -- ^ the subcommand that opens it ("psql")
  , fancy :: { name :: String, cmd :: FancyCmd } -- ^ pgcli / mycli / litecli
  , url :: Creds -> Int -> String -- ^ connection URL for a host port
  , studioSupported :: Os -> Boolean -- ^ whether drizzle-kit can reach it on that guest
  , migrations :: Maybe Migrations -- ^ host-side migration tool, if any
  , dialect :: String -- ^ drizzle-kit dialect
  , driver :: String -- ^ the npm driver drizzle-kit needs for it
  }

-- | Single-quote a string for a POSIX shell.
shellQuote :: String -> String
shellQuote s = "'" <> String.replaceAll (String.Pattern "'") (String.Replacement "'\\''") s <> "'"

-- | Prefix a command with the package prefixes BSD guests keep off the
-- | agent's PATH.
withBsdPath :: String -> Array String
withBsdPath cmd = [ "sh", "-c", "PATH=/usr/local/bin:/usr/pkg/bin:$PATH; exec " <> cmd ]
