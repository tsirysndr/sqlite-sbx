-- | The commands, written against `Sbx.Profile` so the same module serves
-- | every database sandbox.
module Sbx.App (run) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Docker as Docker
import Bsdkrun.Exec as Exec
import Bsdkrun.Host as Host
import Bsdkrun.Options as Options
import Bsdkrun.Port as Port
import Bsdkrun.Sandbox as Sandbox
import Bsdkrun.Types (Sandbox, SandboxInfo, ZfsVolumeInfo)
import Bsdkrun.Zfs as Zfs
import Control.Alt ((<|>))
import Control.Monad.Error.Class (throwError)
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Nullable (toMaybe)
import Data.String as String
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, delay, finally, forkAff, killFiber)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error, message)
import Foreign.Object as Object
import Sbx.Cli (BranchOpts, Command(..), MigrateCmd(..), StartOpts)
import Sbx.Engine as Engine
import Sbx.Identity as Identity
import Sbx.Parallel as Parallel
import Sbx.Native as Native
import Sbx.Profile (ClientCmd(..), Creds, FancyCmd(..), Migrations, Os(..), Profile, osName, parseOs)
import Sbx.State (State)
import Sbx.State as State

run :: Profile -> Command -> Aff Int
run = Parallel.run runBase

runBase :: Profile -> Command -> Aff Int
runBase p = case _ of
  OnBranch _ _ -> fail "Internal branch dispatch error"
  Start o -> start p o
  Stop -> stop p
  Status -> status p
  Shell -> shell p
  Exec o -> exec p o
  Logs o -> logs p o
  Branch o -> branch p o
  Checkout o -> checkout p o
  Url -> url p
  Client -> client p
  Fancy -> fancy p
  Studio o -> studio p o
  Drizzle args -> drizzle p args
  Doctor -> doctor p
  Destroy o -> destroy p o
  Migrate m -> migrate p m
  Tool args -> runMigrationTool p args Nothing
  Setup -> setup p

-- Helpers ------------------------------------------------------------------

say :: String -> Aff Unit
say = liftEffect <<< log

fail :: forall a. String -> Aff a
fail = throwError <<< error

findMachine :: Profile -> Aff (Maybe SandboxInfo)
findMachine p = B.list true <#> Array.find \m -> toMaybe m.name == Just p.tool

findVolume :: Profile -> Aff (Maybe ZfsVolumeInfo)
findVolume p = Zfs.list <#> Array.find (_.name >>> eq (Identity.volumeName p.tool))

requireVolume :: Profile -> Aff ZfsVolumeInfo
requireVolume p = findVolume p >>= maybe (fail ("no data volume yet — run `" <> p.tool <> " start` first")) pure

requireState :: Profile -> Aff State
requireState p = liftEffect (State.load p.tool) >>= maybe (fail ("no sandbox yet — run `" <> p.tool <> " start`")) pure

-- | Where the server runs: a VM of its own (BSD guests), or a container in
-- | the shared Docker engine VM (Linux).
data Runtime = Vm Sandbox | Container String

requireRunning :: Profile -> Aff { runtime :: Runtime, state :: State }
requireRunning p = do
  state <- requireState p
  os <- stateOs state
  case os of
    Linux -> do
      up <- Engine.isRunning p
      unless up $ fail (p.tool <> " is stopped — run `" <> p.tool <> " start`")
      pure { runtime: Container (Engine.containerName p), state }
    _ -> do
      info <- findMachine p >>= maybe (fail ("the VM is gone — run `" <> p.tool <> " start`")) pure
      unless info.running $ fail (p.tool <> " is stopped — run `" <> p.tool <> " start`")
      box <- B.get info.id
      pure { runtime: Vm box, state }

-- | Whether the server's VM or container is up.
serverRunning :: Profile -> Aff Boolean
serverRunning p = liftEffect (State.load p.tool) >>= case _ of
  Just s | parseOs s.os == Just Linux -> Engine.isRunning p
  _ -> findMachine p <#> maybe false _.running

-- | A PTY session with the database: in the guest, or, when the server
-- | image has no CLIs, in a helper container sharing the data branch.
interactive :: Profile -> State -> Runtime -> Array String -> Aff Int
interactive _ _ (Vm box) argv = Sandbox.execInteractive argv box
interactive p st (Container name) argv = Engine.toolImage p >>= case _ of
  Nothing -> Docker.dockerAttached ([ "exec", "-it", name ] <> argv)
  Just image -> Docker.dockerAttached ([ "run", "--rm", "-it", "-v", Engine.mountPoint p st.branch <> ":" <> p.dataDir Linux, image ] <> argv)

-- | A command with the terminal's stdin, stdout and stderr bound to it.
attached :: Runtime -> Boolean -> Array String -> Aff Int
attached (Vm box) tty argv = Sandbox.execAttached tty argv box
attached (Container name) tty argv = Docker.dockerAttached ([ "exec", if tty then "-it" else "-i", name ] <> argv)

-- | Exit status 0 of a command in the guest; false while it cannot run.
probeIn :: Runtime -> Array String -> Aff Boolean
probeIn (Vm box) argv = probe argv box
probeIn (Container name) argv = Docker.docker ([ "exec", name ] <> argv) <#> (_.exitCode >>> eq 0)

-- | The branch a volume has mounted (bsdkrun records it even for a stopped
-- | holder); `main` on a volume nothing has imported yet.
mountedBranch :: ZfsVolumeInfo -> Maybe String
mountedBranch vol = Array.head (Array.concatMap _.mounts vol.attachedTo) <#> _.branch

currentBranch :: Profile -> Aff String
currentBranch p = do
  vol <- findVolume p
  st <- liftEffect (State.load p.tool)
  pure $ fromMaybe "main" ((st <#> _.branch) <|> (vol >>= mountedBranch))

branchNames :: ZfsVolumeInfo -> Array String
branchNames vol = Array.nub ([ "main" ] <> map _.name vol.branches)

creds :: State -> Creds
creds st = { user: st.user, password: st.password, db: st.db }

stateOs :: State -> Aff Os
stateOs st = maybe (fail ("state file names an unknown OS '" <> st.os <> "'")) pure (parseOs st.os)

describe :: Profile -> State -> String
describe p st = case parseOs st.os of
  Just Linux -> "linux " <> p.image st.version <> " (container in " <> Docker.machineName <> ")"
  _ -> st.os <> (if st.version == "" then "" else " " <> st.version)

-- | Exit status of a command in the guest; false while the agent is not up.
probe :: Array String -> Sandbox -> Aff Boolean
probe argv box = attempt (B.exec argv box) <#> either (const false) (_.exitCode >>> eq 0)

waitFor :: String -> Int -> Aff Boolean -> Aff Unit
waitFor what seconds check = go 0
  where
  go n
    | n >= seconds = fail (what <> " did not come up within " <> show seconds <> "s")
    | otherwise = check >>= \ok -> unless ok (delay (Milliseconds 1000.0) *> go (n + 1))

waitReady :: Profile -> Os -> State -> Runtime -> Aff Unit
waitReady p os st rt = do
  say ("Waiting for " <> p.product <> " ...")
  waitFor p.product 180 do
    alive <- case rt of
      Vm box -> B.isRunning box
      Container _ -> Engine.isRunning p
    unless alive $ fail case rt of
      Vm _ -> "the VM exited while " <> p.product <> " was starting; `" <> p.tool <> " log` and `" <> p.tool <> " log --boot` say why"
      Container _ -> "the container exited while " <> p.product <> " was starting; `" <> p.tool <> " log` says why"
    probeIn rt (p.ready os st.version (creds st))

-- | The profile's setup script, if any: idempotent, run as root through the
-- | agent on every start (the first run installs packages).
provision :: Profile -> Boolean -> Os -> Creds -> Sandbox -> Aff Unit
provision p stream os c box = for_ (p.provision os) \script -> do
  waitAgent p os box
  waitMounted p os box
  say ("Preparing " <> p.product <> " on " <> osName os <> " (the first time installs packages, which takes a minute or two) ...")
  let
    env = Object.fromFoldable [ "SBX_USER" /\ c.user, "SBX_PASSWORD" /\ c.password, "SBX_DB" /\ c.db ]
    opts = Exec.options # Exec.withEnv env
      # (if stream then Exec.withStdout Native.writeStdout >>> Exec.withStderr Native.writeStderr else identity)
  r <- B.execWith [ "sh", "-c", script ] opts box
  unless (r.exitCode == 0) do
    -- Quiet starts keep the output for the failure report.
    unless stream $ say (String.trim (r.stdout <> "\n" <> r.stderr))
    fail ("provisioning failed with exit " <> show r.exitCode)

-- | Wait for the guest agent. A BSD guest whose root disk was just grown
-- | resizes its file system and reboots (NetBSD does), which a detached
-- | machine reports as a clean exit: boot it again, once.
waitAgent :: Profile -> Os -> Sandbox -> Aff Unit
waitAgent p os box = go (isJust (p.rootDisk os)) 0
  where
  go mayReboot n
    | n >= 180 = fail "the guest agent did not come up within 180s"
    | otherwise = B.status box >>= case _ of
        Just m | m.running -> do
          ok <- probe [ "sh", "-c", "true" ] box
          unless ok (delay (Milliseconds 1000.0) *> go mayReboot (n + 1))
        Just m | mayReboot, maybe true (_ == 0) (toMaybe m.exitCode) -> do
          say "The guest grew its root disk and rebooted; starting it again ..."
          for_ m.ports \f -> ensurePort p f.host
          void (B.start box)
          go false 0
        _ -> fail ("the VM exited at boot; `" <> p.tool <> " log --boot` says why")

-- | bsdkrun imports a machine's ZFS volumes from a hook that runs beside the
-- | boot once the agent answers: wait for the data branch to be mounted. A
-- | fresh NetBSD guest gets its ZFS modules installed by that hook and can
-- | only load them at boot, so it is restarted once when the mount does not
-- | come: right away once the modules are in place, else after the wait.
waitMounted :: Profile -> Os -> Sandbox -> Aff Unit
waitMounted p os box = go (os == NetBSD)
  where
  dir = p.dataDir os
  mounted = probe [ "sh", "-c", "mount | grep -q ' on " <> dir <> " '" ] box
  modulesInstalledButNotLoaded = do
    m <- B.status box
    prepared <- maybe (pure false) (\i -> liftEffect (Native.fileExists (Native.pathJoin i.stateDir "zfs-netbsd-ready"))) m
    if not prepared then pure false else not <$> probe [ "sh", "-c", "modstat | grep -q '^zfs '" ] box
  go mayRestart = do
    outcome <- attempt $ waitFor ("the data branch at " <> dir) 90 do
      up <- mounted
      if up then pure true
      else if mayRestart then modulesInstalledButNotLoaded >>= \restart -> if restart then throwError (error "restart") else pure false
      else pure false
    case outcome of
      Right _ -> pure unit
      Left e
        | mayRestart -> do
            say "NetBSD now loads ZFS at boot: restarting the VM to import the data branch ..."
            void (B.stop box)
            B.status box >>= \m -> for_ m \i -> for_ i.ports \f -> ensurePort p f.host
            void (B.start box)
            waitAgent p os box
            go false
        | otherwise -> throwError e

-- | The engine mirrors a container's published port onto the host a moment
-- | after the container starts: wait for it, so `ready` means reachable.
waitHostPort :: Int -> Aff Unit
waitHostPort port = waitFor ("host port " <> show port) 30 (not <$> Port.isFreeOn "127.0.0.1" port)

-- | The forwarded host port must be free before the VM boots. A gvproxy left
-- | behind by a machine that is gone (bsdkrun does not reap it on stop or
-- | exit) is removed; anything else is reported with a way out.
ensurePort :: Profile -> Int -> Aff Unit
ensurePort p port = do
  -- A forward the engine just withdrew (its container was removed up to
  -- fifteen seconds ago) takes that long to let go of the port.
  free <- settle 40
  unless free do
    reaped <- liftEffect (Native.reapOrphanGvproxies port)
    unless (Array.null reaped) $ say ("Port " <> show port <> " was held by a gvproxy left behind by a machine that is gone (pid " <> String.joinWith ", " (map show reaped) <> "); removed it")
    delay (Milliseconds 500.0)
    free' <- Port.isFreeOn "127.0.0.1" port
    unless free' $ fail ("host port " <> show port <> " is in use; pick another with `" <> p.tool <> " start --port PORT`")
  where
  settle n = do
    free <- Port.isFreeOn "127.0.0.1" port
    if free || n == 0 then pure free else delay (Milliseconds 500.0) *> settle (n - 1)

-- | Everything between a booted VM and a usable server. With `stream`, the
-- | provisioning output shows on the terminal; `start -d` turns that off.
bringUp :: Profile -> Boolean -> Os -> State -> Sandbox -> Aff Unit
bringUp p stream os st box = provision p stream os (creds st) box *> waitReady p os st (Vm box)

-- | Run an action while the VM console streams to the terminal (`start -d`
-- | skips it): everything the console holds for a VM just created, only what
-- | comes next for a restart, so the previous boot is not replayed. The
-- | follower is killed once the action is over.
withConsole :: Boolean -> Boolean -> Sandbox -> Aff Unit -> Aff Unit
withConsole false _ _ act = act
withConsole true fromStart box act = do
  follower <- forkAff (void (attempt (Sandbox.streamConsole fromStart box)))
  finally (killFiber (error "console stream closed") follower) act

-- | The same for a container: its log follows on the terminal meanwhile.
withContainerLogs :: Boolean -> Profile -> Aff Unit -> Aff Unit
withContainerLogs false _ act = act
withContainerLogs true p act = do
  follower <- forkAff (void (attempt (Docker.dockerAttached [ "logs", "-f", Engine.containerName p ])))
  finally (killFiber (error "log stream closed") follower) act

ready :: Profile -> State -> Aff Unit
ready p st = do
  say (p.product <> " is ready" <> (if p.serves st.version then " on 127.0.0.1:" <> show st.port else "") <> " (branch " <> st.branch <> ")")
  say ("  " <> p.url st.version (creds st) st.port)

rootfsVolume :: Profile -> String
rootfsVolume p = p.tool <> "-rootfs"

-- Commands -----------------------------------------------------------------

start :: Profile -> StartOpts -> Aff Int
start p o = do
  st <- liftEffect (State.load p.tool)
  for_ st \s -> for_ o.os \os -> when (osName os /= s.os) $ fail ("this sandbox runs " <> s.os <> ", not " <> osName os <> "; `" <> p.tool <> " destroy` to start over")
  let os = fromMaybe Linux ((st >>= _.os >>> parseOs) <|> o.os)
  when (p.linuxOnly && os /= Linux) $ fail (p.tool <> " runs on Linux only, as a container in the shared Docker engine VM")
  if os == Linux then startLinux p o st else startVm p o st

-- | Linux: the server is a container in the shared engine VM, recreated
-- | from the recorded settings whenever anything about it changes; the
-- | container is disposable, the data branch is not.
startLinux :: Profile -> StartOpts -> Maybe State -> Aff Int
startLinux p o previous = do
  legacy <- findMachine p
  for_ legacy \m -> fail ("a '" <> p.tool <> "' VM (" <> m.id <> ") exists from a version that gave Linux its own VM; `" <> p.tool <> " destroy`, then start again")
  for_ previous \s -> do
    for_ o.version \v -> when (v /= s.version) $ fail ("this sandbox was created with version '" <> s.version <> "'; `" <> p.tool <> " destroy` to change it")
    when (isJust o.user || isJust o.password || isJust o.db) $ say "note: credentials and the database were set when the data was initialised; the flags are ignored"
  let
    version = fromMaybe p.defaultTag (map _.version previous <|> o.version)
    c = case previous of
      Just s -> creds s
      Nothing -> { user: fromMaybe p.defaults.user o.user, password: fromMaybe p.defaults.password o.password, db: fromMaybe p.defaults.db o.db }
    port = fromMaybe (maybe p.guestPort _.port previous) o.port
    cpus = fromMaybe (maybe 2 _.cpus previous) o.cpus
    mem = fromMaybe (maybe 1024 _.mem previous) o.mem
    size = fromMaybe "10G" o.size
  vol <- findVolume p >>= case _ of
    Just v -> pure v
    Nothing -> do
      say ("Creating data volume '" <> p.tool <> "' (" <> size <> ", sparse) ...")
      _ <- Zfs.create p.tool (Just size)
      findVolume p >>= maybe (fail "the volume was created but does not show up") pure
  cur <- currentBranch p
  let branchName = fromMaybe cur o.branch
  unless (Array.elem branchName (branchNames vol)) $
    fail ("no branch '" <> branchName <> "'; branches: " <> String.joinWith ", " (branchNames vol))
  let st = { os: "linux", version, port, user: c.user, password: c.password, db: c.db, branch: branchName, cpus, mem }
  running <- Engine.isRunning p
  let unchanged = maybe false (\s -> s.port == port && s.branch == branchName && branchName == cur) previous
  when (isJust o.cpus || isJust o.mem) $ say ("note: on Linux --cpus/--mem do not limit the container; the engine VM is sized with `bsdkrun docker start --cpus N --mem M`")
  if running && unchanged then do
    say (p.tool <> " is already running (container in " <> Docker.machineName <> ", " <> p.image version <> ")")
    ready p st
    pure 0
  else do
    say ("Starting " <> p.product <> " " <> p.image version <> " as container '" <> Engine.containerName p <> "' in the Docker engine VM, branch " <> branchName <> " at " <> Engine.mountPoint p branchName <> " ...")
    -- The engine first: a stopped one hides the old container, which must
    -- go before the branch can move and before its name is reused.
    Engine.ensureEngine
    Engine.removeContainer p
    Engine.ensureAttached p vol branchName
    ensurePort p port
    liftEffect (State.save p.tool st)
    case p.tools of
      -- The helper image is the server image: build it rather than pull it.
      Just t | p.image version == t.image -> void (Engine.toolImage p)
      _ -> Engine.pullImage p st (not o.detach)
    Engine.runContainer p st c
    withContainerLogs (not o.detach) p (waitReady p Linux st (Container (Engine.containerName p)))
    when (p.serves version) $ waitHostPort port
    ready p st
    pure 0

startVm :: Profile -> StartOpts -> Maybe State -> Aff Int
startVm p o saved = do
  mm <- findMachine p
  case mm, saved of
    Just m, Just s
      | m.running && (o.port == Nothing || o.port == Just s.port) -> do
          say (p.tool <> " is already running (" <> m.id <> ", " <> describe p s <> ")")
          when (isJust o.cpus || isJust o.mem) $ say ("note: --cpus/--mem apply on the next start (`" <> p.tool <> " stop`, then `start --cpus N --mem M`)")
          ready p s
          pure 0
      | otherwise -> do
          for_ o.os \os -> when (osName os /= s.os) $ fail ("this sandbox runs " <> s.os <> ", not " <> osName os <> "; `" <> p.tool <> " destroy` to start over")
          for_ o.version \v -> when (v /= s.version) $ fail ("this sandbox was created with version '" <> s.version <> "'; `" <> p.tool <> " destroy` to change it")
          when (isJust o.user || isJust o.password || isJust o.db) $ say "note: credentials and the database were set when the data was initialised; the flags are ignored"
          cur <- currentBranch p
          case o.port of
            Just port | port /= s.port -> do
              -- A port forward is fixed at creation, but nothing of value is
              -- in the VM: the data is on the branch, so recreate it.
              say ("Changing the forwarded port " <> show s.port <> " -> " <> show port <> ": recreating the VM (the data stays on its branch) ...")
              box <- B.get m.id
              -- A clean stop exports the pool; `rm -f` would just kill the VM.
              when m.running (void (B.stop box))
              void (B.remove true box)
              let branchName = fromMaybe cur o.branch
              create (Just s { branch = branchName }) o
                { os = parseOs s.os, version = Just s.version, user = Just s.user, password = Just s.password, db = Just s.db
                , cpus = o.cpus <|> Just s.cpus, mem = o.mem <|> Just s.mem, branch = Just branchName
                }
            _ -> do
              for_ o.branch \b -> when (b /= cur) $ void (checkout p { name: b, create: false })
              box <- B.get m.id
              when (isJust o.cpus || isJust o.mem) do
                let cpus = fromMaybe s.cpus o.cpus
                let mem = fromMaybe s.mem o.mem
                say ("Setting " <> show cpus <> " vCPU / " <> show mem <> " MiB ...")
                void (B.update cpus mem box)
                liftEffect (State.save p.tool s { cpus = cpus, mem = mem })
              say ("Starting " <> p.tool <> " (" <> m.id <> ") ...")
              s' <- requireState p
              os <- stateOs s'
              ensurePort p s'.port
              withConsole (not o.detach) false box do
                void (B.start box)
                bringUp p (not o.detach) os s' box
              ready p s'
              pure 0
    Just m, Nothing -> fail ("a machine named '" <> p.tool <> "' exists (" <> m.id <> ") but this tool did not record it; remove it with `bsdkrun rm -f " <> m.id <> "` or `" <> p.tool <> " destroy`")
    Nothing, _ -> create saved o
  where
  create previous o' = do
    let
      os = fromMaybe (fromMaybe Linux (previous >>= _.os >>> parseOs)) o'.os
      version = fromMaybe (maybe (if os == Linux then p.defaultTag else "") _.version previous) o'.version
      c = { user: fromMaybe (maybe p.defaults.user _.user previous) o'.user, password: fromMaybe (maybe p.defaults.password _.password previous) o'.password, db: fromMaybe (maybe p.defaults.db _.db previous) o'.db }
      port = fromMaybe (maybe p.guestPort _.port previous) o'.port
      cpus = fromMaybe (maybe 2 _.cpus previous) o'.cpus
      mem = fromMaybe (maybe 1024 _.mem previous) o'.mem
      size = fromMaybe "10G" o'.size
      branchName = fromMaybe (maybe "main" _.branch previous) o'.branch
    vol <- findVolume p >>= case _ of
      Just v -> pure v
      Nothing -> do
        say ("Creating data volume '" <> p.tool <> "' (" <> size <> ", sparse) ...")
        _ <- Zfs.create p.tool (Just size)
        findVolume p >>= maybe (fail "the volume was created but does not show up") pure
    unless (Array.elem branchName (branchNames vol)) $
      fail ("no branch '" <> branchName <> "'; branches: " <> String.joinWith ", " (branchNames vol))
    let
      bsdVersion = if version == "" then identity else Options.withVersion version
      rootDisk os' = maybe identity Options.withDiskSize (p.rootDisk os')
      base = case os of
        Linux -> Options.linux (p.image version) # Options.withEnv (p.env c)
          # (if p.rootfsVolume then Options.withVolume (rootfsVolume p) else identity)
          # maybe identity Options.withCommand (p.command version)
        FreeBSD -> Options.freebsd # bsdVersion # rootDisk FreeBSD
        NetBSD -> Options.netbsd # bsdVersion # rootDisk NetBSD
      opts = base
        # Options.withName p.tool
        # Options.withCpus cpus
        # Options.withMem mem
        # Options.withPorts [ show port <> ":" <> show p.guestPort ]
        # Options.withZfs [ Zfs.target (Identity.volumeName p.tool) (Just branchName) <> ":" <> p.dataDir os ]
      st = { os: osName os, version, port, user: c.user, password: c.password, db: c.db, branch: branchName, cpus, mem }
    say ("Creating " <> describe p st <> " VM '" <> p.tool <> "' with branch " <> branchName <> " at " <> p.dataDir os <> " (" <> show cpus <> " vCPU, " <> show mem <> " MiB) ...")
    ensurePort p port
    box <- B.create opts
    liftEffect (State.save p.tool st)
    say ("VM " <> B.sandboxId box <> " is up")
    withConsole (not o'.detach) true box (bringUp p (not o'.detach) os st box)
    ready p st
    pure 0

stop :: Profile -> Aff Int
stop p = liftEffect (State.load p.tool) >>= case _ of
  Just s | parseOs s.os == Just Linux -> do
    up <- Engine.isRunning p
    if not up then say (p.tool <> " is already stopped") $> 0
    else do
      say ("Stopping container '" <> Engine.containerName p <> "' ...")
      r <- Docker.docker [ "stop", Engine.containerName p ]
      unless (r.exitCode == 0) $ fail ("docker stop: " <> String.trim r.stderr)
      say "stopped"
      pure 0
  _ -> stopVm p

stopVm :: Profile -> Aff Int
stopVm p = findMachine p >>= case _ of
  Nothing -> say ("nothing to stop: no " <> p.tool <> " VM") $> 0
  Just m
    | not m.running -> say (p.tool <> " is already stopped") $> 0
    | otherwise -> do
        say ("Stopping " <> p.tool <> " (" <> m.id <> ") ...")
        _ <- B.get m.id >>= B.stop
        say "stopped"
        pure 0

status :: Profile -> Aff Int
status p = do
  st <- liftEffect (State.load p.tool)
  mm <- findMachine p
  vol <- findVolume p
  tint <- liftEffect Native.colorOutput
  let
    row k v = say ("  " <> String.take 10 (k <> "          ") <> v)
    portOf s = "127.0.0.1:" <> show s.port <> " -> " <> show p.guestPort
    paint code s = if tint then Native.ansi code s else s
    upOrDown up = if up then paint "38;2;0;255;195" "RUNNING" else "STOPPED"
    rest = do
      cur <- currentBranch p
      let names = maybe [ "main" ] branchNames vol
      row "branch" (paint "38;2;0;255;195" cur <> if Array.length names > 1 then "  (" <> String.joinWith ", " names <> ")" else "")
      for_ vol \v -> row "volume" (v.name <> " " <> maybe "" (\s -> s <> " used") (toMaybe v.size) <> (if Array.null v.attachedTo then " (not attached)" else ""))
      for_ st \s -> when p.hasCredentials $ row "database" (s.db <> " as " <> s.user)
      for_ st \s -> row "url" (p.url s.version (creds s) s.port)
  case st, mm of
    Nothing, Nothing -> say ("no sandbox yet — run `" <> p.tool <> " start`") $> 0
    Just s, Nothing | parseOs s.os == Just Linux -> do
      engine <- Docker.status
      c <- Engine.container p
      let up = maybe false (_.state >>> eq "running") c
      say p.tool
      row "status" (upOrDown up)
      row "engine" (Docker.machineName <> " " <> (if engine.running then paint "38;2;0;255;195" "RUNNING" else if isJust (toMaybe engine.machineId) then "STOPPED" else "not created"))
      row "container" case c of
        Nothing -> "not created (`" <> p.tool <> " start` creates it)"
        Just k -> k.id <> ", " <> describe p s <> ", " <> k.status
      when (p.serves s.version) $ row "port" (portOf s)
      rest
      when (up && p.serves s.version) do
        ok <- probeIn (Container (Engine.containerName p)) (p.ready Linux s.version (creds s))
        row "server" (if ok then "accepting connections" else "not accepting connections yet")
      pure 0
    _, _ -> do
      say p.tool
      case mm of
        Nothing -> do
          row "status" "STOPPED"
          row "vm" "not created (state recorded; `start` recreates it)"
        Just m -> do
          -- 143 is SIGTERM: what `stop` sends, not a failure.
          let exited = maybe "" (\code -> if code == 0 || code == 143 then "" else " (exited with " <> show code <> ")") (toMaybe m.exitCode)
          row "status" (upOrDown m.running <> (if m.running then "" else exited))
          row "vm" (m.id <> ", " <> maybe m.image (describe p) st <> ", " <> show m.cpus <> " vCPU / " <> show m.mem <> " MiB")
      for_ st \s -> row "port" (portOf s)
      rest
      case st, mm of
        Just s, Just m | m.running -> do
          os <- stateOs s
          box <- B.get m.id
          ok <- probe (p.ready os s.version (creds s)) box
          row "server" (if ok then "accepting connections" else "not accepting connections yet")
        _, _ -> pure unit
      pure 0

shell :: Profile -> Aff Int
shell p = requireRunning p >>= _.runtime >>> case _ of
  Vm box -> Sandbox.shell box
  Container name -> Docker.dockerAttached [ "exec", "-it", name, "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh" ]

exec :: Profile -> { tty :: Boolean, command :: Array String } -> Aff Int
exec p o = do
  when (Array.null o.command) $ fail ("nothing to run — `" <> p.tool <> " exec CMD...`")
  requireRunning p >>= \r -> attached r.runtime o.tty o.command

-- | The server's log: the VM console for a BSD guest, the container's for
-- | Linux (`--boot` then means the engine VM's boot log).
logs :: Profile -> { follow :: Boolean, boot :: Boolean } -> Aff Int
logs p o = do
  st <- requireState p
  os <- stateOs st
  case os of
    Linux | not o.boot -> do
      c <- Engine.container p
      when (isNothing' c) $ fail ("no container — run `" <> p.tool <> " start`")
      if o.follow then Docker.dockerAttached [ "logs", "-f", Engine.containerName p ]
      else do
        r <- Docker.docker [ "logs", Engine.containerName p ]
        say (String.trim (r.stdout <> "\n" <> r.stderr)) $> r.exitCode
    Linux -> do
      engine <- Docker.status
      id <- maybe (fail "the engine VM has not been created yet") pure (toMaybe engine.machineId)
      box <- B.get id
      if o.follow then Sandbox.followLogs true box else (B.logs true box >>= say) $> 0
    _ -> do
      m <- findMachine p >>= maybe (fail ("no VM — run `" <> p.tool <> " start`")) pure
      box <- B.get m.id
      if o.follow then Sandbox.followLogs o.boot box
      else (B.logs o.boot box >>= say) $> 0
  where
  isNothing' = case _ of
    Nothing -> true
    Just _ -> false

branch :: Profile -> BranchOpts -> Aff Int
branch p o = case o.name, o.arg of
  Just "ls", _ -> branch p o { name = Nothing }
  Just "list", _ -> branch p o { name = Nothing }
  Just "rm", Just name -> branch p o { name = Just name, arg = Nothing, delete = true }
  Just "delete", Just name -> branch p o { name = Just name, arg = Nothing, delete = true }
  Just "rm", Nothing -> fail ("which branch? `" <> p.tool <> " branch rm NAME`")
  Just "delete", Nothing -> fail ("which branch? `" <> p.tool <> " branch delete NAME`")
  _, Just extra -> fail ("unexpected argument '" <> extra <> "'")
  _, _ -> branch' p o

branch' :: Profile -> BranchOpts -> Aff Int
branch' p o = case o.name, o.delete of
  Nothing, _ -> do
    vol <- requireVolume p
    cur <- currentBranch p
    let
      origin b = maybe "" (\from -> "  (from " <> from <> ")") (toMaybe b.origin)
      known = map (\b -> b.name /\ origin b) vol.branches
      rows = if Array.any (fst' >>> eq "main") known then known else [ "main" /\ "  (initialised on first start)" ] <> known
    color <- liftEffect Native.colorOutput
    for_ rows \(name /\ note) -> do
      let label = (if name == cur then "* " else "  ") <> name
      say ((if color && name == cur then Native.ansi "38;2;0;255;195" label else label) <> note)
    pure 0
  Just name, true -> do
    vol <- requireVolume p
    cur <- currentBranch p
    when (name == "main") $ fail "main cannot be deleted; `destroy` removes the whole volume"
    when (name == cur) $ fail ("'" <> name <> "' is the mounted branch; checkout another one first")
    unless (Array.elem name (branchNames vol)) $ fail ("no branch '" <> name <> "'")
    Zfs.destroy [ Zfs.target (Identity.volumeName p.tool) (Just name) ] false
    say ("Deleted branch '" <> name <> "'")
    pure 0
  Just name, false -> do
    vol <- requireVolume p
    cur <- currentBranch p
    let from = fromMaybe cur o.from
    when (Array.elem name (branchNames vol)) $ fail ("branch '" <> name <> "' already exists")
    unless (Array.elem from (branchNames vol)) $ fail ("no branch '" <> from <> "' to fork from")
    holder <- liftEffect (State.load p.tool) >>= case _ of
      Just s | parseOs s.os == Just Linux -> Engine.engineRunning
      _ -> findMachine p <#> maybe false _.running
    unless holder $ say "(the VM holding the volume is not running: a short-lived FreeBSD helper does the fork)"
    say ("Forking " <> from <> " -> " <> name <> " ...")
    _ <- Zfs.branch (Identity.volumeName p.tool) name (Just from)
    say ("Branch '" <> name <> "' created. Switch to it with `" <> p.tool <> " checkout " <> name <> "`")
    pure 0
  where
  fst' (a /\ _) = a

checkout :: Profile -> { name :: String, create :: Boolean } -> Aff Int
checkout p o = do
  vol <- requireVolume p
  st <- requireState p
  os <- stateOs st
  cur <- currentBranch p
  when o.create do
    when (Array.elem o.name (branchNames vol)) $ fail ("branch '" <> o.name <> "' already exists")
    say ("Forking " <> cur <> " -> " <> o.name <> " ...")
    void (Zfs.branch (Identity.volumeName p.tool) o.name (Just cur))
  unless (o.create || Array.elem o.name (branchNames vol)) $
    fail ("no branch '" <> o.name <> "' (`" <> p.tool <> " branch` lists them; `checkout -b " <> o.name <> "` creates it)")
  if o.name == cur then say ("already on '" <> o.name <> "'") $> 0
  else if os == Linux then do
    running <- Engine.isRunning p
    when running $ say ("Stopping container '" <> Engine.containerName p <> "' ...")
    Engine.removeContainer p
    vol' <- requireVolume p
    Engine.ensureAttached p vol' o.name
    let st' = st { branch = o.name }
    liftEffect (State.save p.tool st')
    when running do
      say ("Starting " <> p.tool <> " on branch " <> o.name <> " ...")
      Engine.runContainer p st' (creds st)
      waitReady p Linux st' (Container (Engine.containerName p))
      when (p.serves st.version) $ waitHostPort st.port
    say ("Switched to branch '" <> o.name <> "'")
    pure 0
  else do
    mm <- findMachine p
    case mm of
      Nothing -> do
        liftEffect (State.save p.tool st { branch = o.name })
        say ("Branch '" <> o.name <> "' will be mounted on the next start")
      Just m -> do
        box <- B.get m.id
        when m.running do
          say ("Stopping " <> p.tool <> " ...")
          void (B.stop box)
        for_ (mountedBranch vol) \b -> void (Zfs.detach (Zfs.target (Identity.volumeName p.tool) (Just b)) m.id)
        _ <- Zfs.attachAt (Zfs.target (Identity.volumeName p.tool) (Just o.name)) m.id (Just (p.dataDir os))
        liftEffect (State.save p.tool st { branch = o.name })
        when m.running do
          say ("Starting " <> p.tool <> " on branch " <> o.name <> " ...")
          _ <- B.start box
          bringUp p false os st box
        say ("Switched to branch '" <> o.name <> "'")
    pure 0

url :: Profile -> Aff Int
url p = do
  st <- requireState p
  say (p.url st.version (creds st) st.port)
  pure 0

client :: Profile -> Aff Int
client p = do
  { runtime, state: st } <- requireRunning p
  os <- stateOs st
  case p.client of
    Guest argv -> interactive p st runtime (argv os st.version (creds st))
    Host argv -> do
      node <- liftEffect Native.nodePath
      root <- liftEffect Native.toolRoot
      Native.spawnInherit node (map (Native.pathJoin root) (Array.take 1 (argv st.port (creds st))) <> Array.drop 1 (argv st.port (creds st))) (Object.singleton "DATABASE_URL" (p.url st.version (creds st) st.port))

-- | `uvx` or `pipx run`: how a Python CLI is run on the host without
-- | installing it by hand.
pythonRunner :: Aff { cmd :: String, args :: Array String, name :: String }
pythonRunner = do
  uvx <- liftEffect (Native.findExecutable "uvx") <#> toMaybe
  pipx <- liftEffect (Native.findExecutable "pipx") <#> toMaybe
  case uvx, pipx of
    Just cmd, _ -> pure { cmd, args: [], name: "uvx" }
    _, Just cmd -> pure { cmd, args: [ "run" ], name: "pipx" }
    _, _ -> fail "neither uvx nor pipx is on PATH; install uv (brew install uv) or pipx"

fancy :: Profile -> Aff Int
fancy p = do
  { runtime, state: st } <- requireRunning p
  os <- stateOs st
  case p.fancy.cmd of
    GuestTool argv -> interactive p st runtime (argv os st.version (creds st))
    HostTool argv -> do
      runner <- pythonRunner
      Native.spawnInherit runner.cmd (runner.args <> argv (creds st) st.port) Object.empty

-- | How to run drizzle-kit: this package's own copy under node_modules when
-- | running from a checkout, otherwise a `drizzle-kit` on PATH (the compiled
-- | single binary has no node_modules; `npm i -g drizzle-kit drizzle-orm
-- | <driver>` provides one).
drizzleKit :: Aff { cmd :: String, args :: Array String, where :: String }
drizzleKit = do
  root <- liftEffect Native.toolRoot
  node <- liftEffect Native.nodePath
  let bin = Native.pathJoin root "node_modules/drizzle-kit/bin.cjs"
  local <- liftEffect (Native.fileExists bin)
  onPath <- liftEffect (Native.findExecutable "drizzle-kit") <#> toMaybe
  case local, onPath of
    true, _ -> pure { cmd: node, args: [ bin ], where: bin }
    _, Just cmd -> pure { cmd, args: [], where: cmd }
    _, _ -> fail "drizzle-kit is not installed: `npm install` in the package, or `npm i -g drizzle-kit drizzle-orm` for the binary"

-- | A drizzle config for the sandbox, written under the tool's config dir.
drizzleConfig :: Profile -> State -> Aff String
drizzleConfig p st = liftEffect do
  dir <- Native.configDir p.tool
  let path = Native.pathJoin dir "drizzle.config.ts"
  Native.writeText path $ String.joinWith "\n"
    [ "// Written by " <> p.tool <> " for `" <> p.tool <> " studio` and `" <> p.tool <> " drizzle`."
    , "export default {"
    , "  dialect: \"" <> p.dialect <> "\","
    , "  dbCredentials: { url: \"" <> p.url st.version (creds st) st.port <> "\" },"
    , "};"
    , ""
    ]
  pure path

studio :: Profile -> { port :: Int, host :: String } -> Aff Int
studio p o = do
  { state: st } <- requireRunning p
  os <- stateOs st
  unless (p.studioSupported os st.version) $ fail ("Drizzle Studio needs a network-reachable server, which " <> p.product <> " " <> st.version <> " on " <> st.os <> " does not provide")
  kit <- drizzleKit
  cfg <- drizzleConfig p st
  say ("Drizzle Studio on " <> p.url st.version (creds st) st.port <> " — open https://local.drizzle.studio")
  Native.spawnInherit kit.cmd (kit.args <> [ "studio", "--config", cfg, "--port", show o.port, "--host", o.host ]) Object.empty

drizzle :: Profile -> Array String -> Aff Int
drizzle p args = do
  st <- requireState p
  os <- stateOs st
  unless (p.studioSupported os st.version) $ fail ("drizzle-kit needs a network-reachable server, which " <> p.product <> " " <> st.version <> " on " <> st.os <> " does not provide")
  kit <- drizzleKit
  dir <- liftEffect Native.cwd
  own <- liftEffect $ Array.foldM (\acc f -> (acc || _) <$> Native.fileExists (Native.pathJoin dir f)) false
    (map ("drizzle.config." <> _) [ "ts", "js", "mts", "cts", "mjs", "cjs", "json" ])
  args' <-
    if own || Array.elem "--config" args then pure args
    else drizzleConfig p st <#> \cfg -> args <> [ "--config", cfg ]
  Native.spawnInherit kit.cmd (kit.args <> args') (Object.singleton "DATABASE_URL" (p.url st.version (creds st) st.port))

-- Migrations (pgroll) --------------------------------------------------------

migrations :: Profile -> Aff Migrations
migrations p = maybe (fail (p.tool <> " has no migration tool")) pure p.migrations

-- | The tool on PATH, or where `setup` puts it.
migrationTool :: Migrations -> Aff (Maybe String)
migrationTool m = do
  onPath <- liftEffect (Native.findExecutable m.name) <#> toMaybe
  home <- liftEffect Native.homeDir
  let local = Native.pathJoin home (".local/bin/" <> m.name)
  hasLocal <- liftEffect (Native.fileExists local)
  pure (onPath <|> (if hasLocal then Just local else Nothing))

runMigrationTool :: Profile -> Array String -> Maybe String -> Aff Int
runMigrationTool p args dir = do
  m <- migrations p
  st <- requireState p
  bin <- migrationTool m >>= maybe (fail (m.name <> " is not installed — run `" <> p.tool <> " setup`")) pure
  let
    dbUrl = m.url (creds st) st.port
    args' = if Array.any (\a -> a == m.urlFlag || String.take (String.length m.urlFlag + 1) a == m.urlFlag <> "=") args then args else args <> [ m.urlFlag, dbUrl ]
  Native.spawnInheritIn bin args' (Object.singleton m.envVar dbUrl) dir

migrate :: Profile -> MigrateCmd -> Aff Int
migrate p cmd = do
  m <- migrations p
  let
    dirOr = fromMaybe m.dir
    run' args = runMigrationTool p args Nothing
  case cmd of
    MigrateInit -> run' [ "init" ]
    MigrateNew o -> do
      -- Migrations apply in file-name order, so number them: 01_, 02_, ...
      -- unless the name already starts with digits.
      liftEffect (Native.mkdirp m.dir)
      existing <- liftEffect (Native.listDir m.dir) <#> Array.filter (\f -> String.contains (String.Pattern ".yaml") f || String.contains (String.Pattern ".json") f || String.contains (String.Pattern ".yml") f)
      let
        next = Array.length existing + 1
        numbered = String.take 1 o.name # String.toCodePointArray # Array.all (\c -> c >= String.codePointFromChar '0' && c <= String.codePointFromChar '9')
        name = if numbered then o.name else (if next < 10 then "0" else "") <> show next <> "_" <> o.name
      runMigrationTool p ([ "create", "--name", name ] <> (if o.empty then [ "--empty" ] else []) <> (if o.json then [ "--json" ] else [])) (Just m.dir)
    MigrateUp o -> run' ([ "migrate", dirOr o.dir ] <> (if o.keepOpen then [] else [ "--complete" ]))
    MigrateStart o -> run' ([ "start", o.file ] <> (if o.complete then [ "--complete" ] else []))
    MigrateComplete -> run' [ "complete" ]
    MigrateRollback -> run' [ "rollback" ]
    MigrateStatus -> run' [ "status" ]
    MigratePull o -> run' [ "pull", dirOr o.dir ]
    MigrateBaseline o -> run' [ "baseline", o.version, dirOr o.dir ]

setup :: Profile -> Aff Int
setup p = do
  m <- migrations p
  installed <- migrationTool m
  case installed of
    Just path -> say (m.name <> " is installed: " <> path)
    Nothing -> do
      brew <- liftEffect (Native.findExecutable "brew") <#> toMaybe
      case brew of
        Just b -> do
          say ("Installing " <> m.name <> " with Homebrew (" <> m.brew <> ") ...")
          code <- Native.spawnInherit b [ "install", m.brew ] Object.empty
          unless (code == 0) $ fail ("brew install exited with " <> show code)
        Nothing -> do
          host <- liftEffect Native.platform
          say ("Looking up the latest " <> m.name <> " release ...")
          body <- Native.fetchText ("https://api.github.com/repos/" <> m.repo <> "/releases/latest")
          tag <- maybe (fail "could not read the release tag") pure (tagOf body)
          home <- liftEffect Native.homeDir
          let
            dest = Native.pathJoin home (".local/bin/" <> m.name)
            asset = "https://github.com/" <> m.repo <> "/releases/download/" <> tag <> "/" <> m.asset host
          say ("Downloading " <> asset <> " ...")
          Native.download asset dest
          say ("Installed " <> dest <> " — make sure ~/.local/bin is on your PATH")
  up <- serverRunning p
  if up then do
    say ("Initialising " <> m.name <> " in the sandbox database ...")
    runMigrationTool p [ "init" ] Nothing
  else do
    say ("The sandbox is not running; `" <> p.tool <> " start` then `" <> p.tool <> " migrate init` initialises " <> m.name <> " in it")
    pure 0
  where
  -- `"tag_name":"v0.16.3"` — enough of a JSON parse for one string field.
  tagOf body = do
    i <- String.indexOf (String.Pattern "\"tag_name\":\"") body
    let rest = String.drop (i + 12) body
    let tag = String.takeWhile (_ /= String.codePointFromChar '"') rest
    if tag == "" then Nothing else Just tag

doctor :: Profile -> Aff Int
doctor p = do
  bin <- attempt (liftEffect Sandbox.resolveBinary)
  okBin <- check "bsdkrun" (either (const Nothing) Just bin) "not found: brew install tsirysndr/tap/bsdkrun"
  version <- attempt Host.version
  _ <- check "version" (either (const Nothing) Just version) "could not run `bsdkrun --version`"
  probed <- attempt Host.probe
  okProbe <- check "hypervisor"
    (case probed of
      Right true -> Just "libkrun context OK"
      _ -> Nothing)
    (case probed of
      Left e -> message e
      Right _ -> "`bsdkrun probe` failed: libkrun or the hypervisor is not usable")
  node <- liftEffect Native.nodeVersion
  let major = fromMaybe 0 (Int.fromString (String.takeWhile (_ /= String.codePointFromChar '.') (String.drop 1 node)))
  okNode <- check "node" (if major >= 22 then Just node else Nothing) (node <> " — Node 22 or newer is required")
  kit <- attempt drizzleKit
  okKit <- check "drizzle-kit" (either (const Nothing) (Just <<< _.where) kit) (either message (const "") kit)
  runner <- attempt pythonRunner
  _ <- case p.fancy.cmd of
    HostTool _ -> check p.fancy.name (either (const Nothing) (\r -> Just ("runs through " <> r.name)) runner) (either message (const "") runner)
    GuestTool _ -> check p.fancy.name (Just "installed in the guest on first start") ""
  okTool <- case p.migrations of
    Nothing -> pure true
    Just m -> do
      tool <- migrationTool m
      ver <- case tool of
        Just b -> Native.capture b [ "--version" ] <#> \r -> Just (String.trim (if r.stdout == "" then r.stderr else r.stdout))
        Nothing -> pure Nothing
      check m.name (ver <#> \v -> v <> maybe "" (" at " <> _) tool) ("not installed: `" <> p.tool <> " setup` installs it")
  dockerCli <- liftEffect (Native.findExecutable "docker") <#> toMaybe
  okDocker <- check "docker" dockerCli "the docker CLI is not on PATH; Linux sandboxes run in bsdkrun's Docker engine, driven by it (brew install docker)"
  engine <- attempt Docker.status
  _ <- check "engine" (Just (case engine of
    Right e | e.running -> Docker.machineName <> " running, Docker " <> fromMaybe "?" (toMaybe e.version) <> ", " <> show (fromMaybe 0 (toMaybe e.containers)) <> " container(s)"
    Right e | isJust (toMaybe e.machineId) -> Docker.machineName <> " stopped (a Linux `start` starts it)"
    Right _ -> "none yet (a Linux `start` creates " <> Docker.machineName <> ")"
    Left e -> "could not ask bsdkrun: " <> message e)) ""
  st <- liftEffect (State.load p.tool)
  mm <- findMachine p
  vol <- findVolume p
  container <- if maybe false (\s -> parseOs s.os == Just Linux) st then Engine.container p else pure Nothing
  let volumeNote = maybe "" (\v -> ", volume with " <> show (Array.length (branchNames v)) <> " branch(es)") vol
  _ <- check "sandbox" (Just (case st, mm, container of
    Nothing, Nothing, _ -> "none yet (`" <> p.tool <> " start`)"
    _, Just m, _ -> "VM " <> m.id <> " " <> (if m.running then "running" else "stopped") <> volumeNote
    Just _, Nothing, Just c -> "container " <> c.id <> " " <> c.state <> volumeNote
    Just s, Nothing, Nothing | parseOs s.os == Just Linux -> "state recorded but no container (`" <> p.tool <> " start` recreates it)" <> volumeNote
    Just _, Nothing, Nothing -> "state recorded but no VM (`" <> p.tool <> " start` recreates it)")) ""
  pure (if okBin && okProbe && okNode && okKit && okTool && okDocker then 0 else 1)
  where
  check name result hint = case result of
    Just detail -> say ("  ok   " <> pad name <> detail) $> true
    Nothing -> say ("  FAIL " <> pad name <> hint) $> false
  pad s = String.take 13 (s <> "             ")

destroy :: Profile -> { yes :: Boolean } -> Aff Int
destroy p o = do
  st <- liftEffect (State.load p.tool)
  mm <- findMachine p
  vol <- findVolume p
  container <- if maybe false (\s -> parseOs s.os == Just Linux) st then Engine.container p else pure Nothing
  if Array.all isNothing' [ void st, void mm, void vol, void container ] then say ("nothing to destroy: no " <> p.tool <> " sandbox") $> 0
  else do
    say "This removes:"
    for_ mm \m -> say ("  VM " <> m.id <> " (" <> (if m.running then "running" else "stopped") <> ")")
    for_ container \c -> say ("  container " <> c.id <> " in " <> Docker.machineName <> " (" <> c.state <> "; the engine itself stays)")
    for_ vol \v -> say ("  data volume '" <> v.name <> "' with branches " <> String.joinWith ", " (branchNames v) <> " — all data")
    rootfs <- Host.volumes <#> Array.find (_.name >>> eq (rootfsVolume p))
    for_ rootfs \v -> say ("  rootfs volume '" <> v.name <> "'")
    for_ st \_ -> say ("  the recorded settings under ~/.config/" <> p.tool)
    ok <-
      if o.yes then pure true
      else do
        tty <- liftEffect Native.isTty
        unless tty $ fail "not a terminal; pass --yes to confirm"
        Native.confirm "Destroy all of it? [y/N] "
    if not ok then say "aborted" $> 1
    else do
      for_ mm \m -> do
        box <- B.get m.id
        when m.running do
          say "Stopping the VM ..."
          void (B.stop box)
        say "Removing the VM ..."
        void (B.remove true box)
      for_ container \_ -> do
        say "Removing the container ..."
        Engine.removeContainer p
      for_ vol \v -> do
        Engine.detachVolume p v
        say ("Destroying volume '" <> v.name <> "' ...")
        Zfs.destroy [ v.name ] true
      for_ rootfs \v -> do
        say ("Removing volume '" <> v.name <> "' ...")
        Host.removeVolumes [ v.name ] true
      liftEffect do
        State.clear p.tool
        dir <- Native.configDir p.tool
        Native.removeFile (Native.pathJoin dir "drizzle.config.ts")
      say "Destroyed."
      pure 0
  where
  isNothing' = case _ of
    Nothing -> true
    Just _ -> false
