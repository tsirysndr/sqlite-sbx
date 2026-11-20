-- | Linux sandboxes share one VM: bsdkrun's Docker engine (`bsdkrun docker`,
-- | the machine `bsdkrun-docker`). Each tool runs its server as a container
-- | in it, with its data branch attached to the engine and bind-mounted into
-- | the container, so a second database costs a container, not a VM.
module Sbx.Engine
  ( mountPoint
  , containerName
  , ensureEngine
  , runtimeVersionAllowed
  , engineRunning
  , ensureAttached
  , detachVolume
  , container
  , isRunning
  , removeContainer
  , pullImage
  , runContainer
  , toolImage
  , serverImage
  ) where

import Prelude
import Bsdkrun.Host as Host
import Bsdkrun.Docker as Docker
import Bsdkrun.Types (DockerContainer, ZfsVolumeInfo)
import Bsdkrun.Zfs as Zfs
import Control.Monad.Error.Class (throwError)
import Data.Int as Int
import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Nullable (toMaybe)
import Data.String as String
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error)
import Foreign.Object as Object
import Sbx.Native as Native
import Sbx.Identity as Identity
import Sbx.Profile (Creds, Os(..), Profile)
import Sbx.State (State)

say :: String -> Aff Unit
say = liftEffect <<< log

-- | Where a data branch is mounted in the engine VM (one path per branch,
-- | so the next branch can mount before the current one lets go); the
-- | container sees it at the profile's Linux data directory.
mountPoint :: Profile -> String -> String
mountPoint p branch = "/mnt/" <> p.tool <> "-" <> branch

containerName :: Profile -> String
containerName p = p.tool

engineRunning :: Aff Boolean
engineRunning = Docker.status <#> _.running

-- | New image stores need the ext4 zeroout fix in bsdkrun 0.12.1.
runtimeVersionAllowed :: String -> Boolean
runtimeVersionAllowed raw = fromMaybe false do
  let version = fromMaybe (String.trim raw) (String.stripPrefix (String.Pattern "bsdkrun ") (String.trim raw))
  case String.split (String.Pattern ".") version of
    [ major, minor, patch ] -> do
      ma <- Int.fromString major
      mi <- Int.fromString minor
      pa <- Array.head (String.split (String.Pattern "-") patch) >>= Int.fromString
      pure (ma > 0 || (ma == 0 && (mi > 12 || (mi == 12 && pa >= 1))))
    _ -> Nothing

-- | The engine up: created with room for a few databases the first time,
-- | resumed as it is afterwards (`bsdkrun docker start --cpus/--mem` sizes
-- | it; the tools do not).
ensureEngine :: Aff Unit
ensureEngine = do
  st <- Docker.status
  unless st.running do
    say
      ( if isNothing (toMaybe st.machineId) then "Creating the Docker engine VM '" <> Docker.machineName <> "' (2 vCPU, 2048 MiB, 20G image store; shared by every Linux sandbox) ..."
        else "Starting the Docker engine VM '" <> Docker.machineName <> "' ..."
      )
    -- Restarting a live proxy loses its record of existing gvproxy forwards.
    -- Reuse running engines; App verifies the resulting host listener.
    if isNothing (toMaybe st.machineId) then do
      version <- Host.version
      unless (runtimeVersionAllowed version) $
        throwError (error ("creating a Docker image store requires bsdkrun >= 0.12.1; found " <> String.trim version))
      -- Let bsdkrun initialize and mount its own image store. Native overlay
      -- snapshots need ext4 rather than the VM's virtio-fs root on Linux.
      -- Only choose a disk size for a new VM; existing engines keep their data.
      code <- Native.runBsdkrun
        [ "docker", "start", "--cpus", "2", "--mem", "2048"
        , "--publish-bind", "127.0.0.1", "--disk-size", "20G"
        ]
      unless (code == 0) $ throwError (error "starting the Docker engine failed")
    else
      void (Docker.start { cpus: 2, mem: 2048, publishBind: Just "127.0.0.1" })

heldByEngine :: ZfsVolumeInfo -> Boolean
heldByEngine vol = Array.any (\a -> toMaybe a.machineName == Just Docker.machineName) vol.attachedTo

mountedInEngine :: ZfsVolumeInfo -> Array { branch :: String, mountpoint :: String }
mountedInEngine vol = Array.concatMap _.mounts (Array.filter (\a -> toMaybe a.machineName == Just Docker.machineName) vol.attachedTo)

-- | `VOL@branch` mounted at its mountpoint in the engine, and no other
-- | branch of the volume. A volume the engine does not hold yet attaches
-- | while it is stopped (a virtio disk cannot be hot-plugged), which
-- | restarts a running engine once; another branch of a held volume mounts
-- | live, before the old one is let go of (letting go of the last mount
-- | drops the disk, and mounting again would be a hot-plug). The container
-- | must be gone first: it is what holds the old mount open.
ensureAttached :: Profile -> ZfsVolumeInfo -> String -> Aff Unit
ensureAttached p vol branch
  | heldByEngine vol = do
      let mounted = mountedInEngine vol
      unless (Array.any (\m -> m.branch == branch && m.mountpoint == mountPoint p branch) mounted) $
        void (Zfs.attachAt (target p branch) Docker.machineName (Just (mountPoint p branch)))
      for_ (Array.filter (\m -> m.branch /= branch && String.take (String.length ("/mnt/" <> p.tool <> "-")) m.mountpoint == "/mnt/" <> p.tool <> "-") mounted) \m -> void (Zfs.detach (target p m.branch) Docker.machineName)
  | otherwise = do
      st <- Docker.status
      -- Nothing to attach to until the engine VM exists.
      when (isNothing (toMaybe st.machineId)) ensureEngine
      st' <- Docker.status
      when st'.running do
        say ("Attaching the data volume to the engine VM: a new disk needs it restarted (its other containers come back on their own) ...")
        Docker.stop
      void (Zfs.attachAt (target p branch) Docker.machineName (Just (mountPoint p branch)))
      ensureEngine

target :: Profile -> String -> String
target p b = Zfs.target (Identity.volumeName p.tool) (Just b)

-- | Let go of the whole volume (every branch) in the engine.
detachVolume :: Profile -> ZfsVolumeInfo -> Aff Unit
detachVolume p vol = when (heldByEngine vol) $ void (Zfs.detach (Zfs.target (Identity.volumeName p.tool) Nothing) Docker.machineName)

-- | The tool's container, running or not; `Nothing` while the engine is
-- | down, since nothing can be asked.
container :: Profile -> Aff (Maybe DockerContainer)
container p = do
  up <- engineRunning
  if not up then pure Nothing
  else Docker.containers true <#> Array.find (_.name >>> eq (containerName p))

isRunning :: Profile -> Aff Boolean
isRunning p = container p <#> maybe false (_.state >>> eq "running")

-- | Remove the container, stopping it first. It is disposable: everything
-- | of value is on the branch, and `start` recreates it from the recorded
-- | settings.
removeContainer :: Profile -> Aff Unit
removeContainer p = container p >>= \c -> for_ c \_ -> do
  r <- Docker.docker [ "rm", "-f", containerName p ]
  unless (r.exitCode == 0) $ throwError (error ("docker rm: " <> String.trim r.stderr))

-- | The image present in the engine, pulling it (with progress when
-- | `stream`) when it is not.
pullImage :: Profile -> State -> Boolean -> Aff Unit
pullImage p st stream = do
  let image = p.image st.version
  have <- Docker.docker [ "image", "inspect", image ] <#> (_.exitCode >>> eq 0)
  unless have do
    say ("Pulling " <> image <> " into the engine ...")
    code <-
      if stream then Docker.dockerAttached [ "pull", image ]
      else Docker.docker [ "pull", image ] <#> _.exitCode
    unless (code == 0) $ throwError (error ("docker pull " <> image <> " failed"))

-- | Create and start the container from the recorded settings: the host
-- | port published (bsdkrun mirrors it onto the host's loopback), the
-- | branch bind-mounted at the data directory, and `unless-stopped` so an
-- | engine restart brings it back. No CPU or memory limit: the engine's
-- | kernel has no CFS scheduler, so the engine's own size is the limit.
runContainer :: Profile -> State -> Creds -> Aff Unit
runContainer p st c = do
  let
    env = Array.concat (Object.toArrayWithKey (\k v -> [ "-e", k <> "=" <> v ]) (p.env c))
    args =
      [ "run", "-d", "--name", containerName p, "--restart", "unless-stopped"
      , "-v", mountPoint p st.branch <> ":" <> p.dataDir Linux
      ]
      -- On every interface of the VM (gvproxy cannot reach its loopback);
      -- the engine binds it to 127.0.0.1 on the host.
      <> (if p.serves st.version then [ "-p", show st.port <> ":" <> show p.guestPort ] else [])
      <> env <> [ serverImage p st.version ] <> fromMaybe [] (p.command st.version)
  r <- Docker.docker args
  unless (r.exitCode == 0) $ throwError (error ("docker run: " <> String.trim r.stderr))

-- | The helper image's full name: tagged with its Dockerfile's hash, so a
-- | changed Dockerfile builds a new image instead of reusing the old one.
toolsTag :: { image :: String, dockerfile :: String } -> String
toolsTag t = t.image <> ":" <> String.take 12 (Native.sha256 t.dockerfile)

-- | The image a version runs as the container: the helper image when the
-- | profile names it (server-less engines), else the version's own.
serverImage :: Profile -> String -> String
serverImage p version = case p.tools of
  Just t | p.image version == t.image -> toolsTag t
  _ -> p.image version

-- | The profile's helper image for the CLIs, built in the engine the first
-- | time from its inline Dockerfile (a context directory under the tool's
-- | config dir; the engine keeps the image).
toolImage :: Profile -> Aff (Maybe String)
toolImage p = case p.tools of
  Nothing -> pure Nothing
  Just t -> do
    let image = toolsTag t
    have <- Docker.docker [ "image", "inspect", image ] <#> (_.exitCode >>> eq 0)
    unless have do
      say ("Building the " <> image <> " image (the CLIs) in the engine ...")
      dir <- liftEffect do
        d <- Native.configDir p.tool <#> \c -> Native.pathJoin c "tools"
        Native.mkdirp d
        Native.writeText (Native.pathJoin d "Dockerfile") t.dockerfile
        pure d
      code <- Docker.dockerAttached [ "build", "-t", image, dir ]
      unless (code == 0) $ throwError (error ("docker build " <> image <> " failed"))
    pure (Just image)
