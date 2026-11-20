-- | Parallel servers share a pool, never a writable database directory.
module Sbx.Parallel (run, entries, selectPort, emptyStart) where
import Prelude
import Bsdkrun as B
import Bsdkrun.Types (ZfsVolumeInfo)
import Bsdkrun.Docker as Docker
import Bsdkrun.Port as Port
import Bsdkrun.Sandbox as Sandbox
import Bsdkrun.Zfs as Zfs
import Control.Monad.Error.Class (throwError)
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Nullable (toMaybe)
import Data.Traversable (traverse)
import Effect.Aff (Aff, bracket, delay)
import Data.Time.Duration (Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error)
import Sbx.BsdServer as BSD
import Sbx.Cli (Command(..), BranchOpts, StartOpts)
import Sbx.Engine as Engine
import Sbx.Identity as I
import Sbx.Native as N
import Sbx.ParallelNative as PN
import Sbx.Profile (Profile, shellQuote, osName)
import Sbx.State (State)
import Sbx.State as State

type Entry = { name :: String, tool :: String, running :: Boolean }
type Runner = Profile -> Command -> Aff Int
say :: String -> Aff Unit
say = liftEffect <<< log
fail :: forall a. String -> Aff a
fail = throwError <<< error
root :: Profile -> Profile
root p = p {tool = I.volumeName p.tool}
path :: Profile -> Aff String
path p = liftEffect (N.configDir (I.volumeName p.tool) <#> flip N.pathJoin "branches.json")
entries :: Profile -> Aff (Array Entry)
entries p = path p >>= liftEffect <<< N.readJson <#> fromMaybe [] <<< toMaybe
saveEntries :: Profile -> Array Entry -> Aff Unit
saveEntries p values = path p >>= \file -> liftEffect (PN.writeJson file values)
locked :: forall a. Profile -> Aff a -> Aff a
locked p action = do
  dir <- liftEffect (N.configDir (I.volumeName p.tool) <#> flip N.pathJoin "branches.lock")
  bracket (liftEffect (PN.lock dir)) (const (liftEffect (PN.unlock dir))) (const action)
state :: Profile -> Aff State
state p = liftEffect (State.load p.tool) >>= maybe (fail "No sandbox state; run start first") pure
volume :: Profile -> Aff ZfsVolumeInfo
volume p = Zfs.list >>= maybe (fail "No ZFS data volume; run start first") pure <<< A.find (\v -> v.name == I.volumeName p.tool)

emptyStart :: StartOpts
emptyStart = {os: Nothing, version: Nothing, port: Nothing, user: Nothing, password: Nothing, db: Nothing, cpus: Nothing, mem: Nothing, branch: Nothing, size: Nothing, detach: true}

-- Testable allocator: stopped servers retain reservations as well. A listener
-- probe is still necessary for ports used by other applications/tools.
selectPort :: Array Int -> (Int -> Aff Boolean) -> Maybe Int -> Int -> Aff Int
selectPort reservations probePort requested initial = case requested of
  Just n -> do
    unless (n > 0 && n <= 65535) $ fail "Port must be between 1 and 65535"
    when (A.elem n reservations) $ fail ("Port " <> show n <> " is reserved by another branch")
    free <- probePort n
    unless free $ fail ("Port " <> show n <> " is already in use")
    pure n
  Nothing -> go (max 1024 initial)
  where
  go n | n > 65535 = fail "No free branch port remains; choose a port with --port"
  go n = if A.elem n reservations then go (n + 1) else do
    free <- probePort n
    if free then pure n else go (n + 1)

reserved :: Profile -> String -> Aff (Array Int)
reserved p except = do
  list <- entries p
  states <- traverse (\tool -> liftEffect (State.load tool)) ([I.volumeName p.tool] <> map _.tool list)
  pure $ A.mapMaybe (\pair -> case pair of
    Just s | s.port > 0 -> Just s.port
    _ -> Nothing) (A.mapWithIndex (\i s -> if A.index ([I.volumeName p.tool] <> map _.tool list) i == Just except then Nothing else s) states)

hasPort :: Profile -> State -> Boolean
hasPort p st = p.serves st.version

run :: Runner -> Profile -> Command -> Aff Int
run base p cmd = do
  activeFile <- liftEffect (N.configDir (I.volumeName p.tool) <#> flip N.pathJoin "active.json")
  active <- liftEffect (N.readJson activeFile) <#> toMaybe
  list <- entries p
  let selected = if I.isInstance p.tool then Just p else case active of
        Nothing -> Just p
        Just name -> map (\entry -> p {tool = entry.tool}) (A.find (\e -> e.name == name) list)
  case cmd of
    OnBranch _ _ -> dispatch base (root p) cmd
    Checkout _ -> dispatch base (root p) cmd
    Destroy _ -> dispatch base p cmd
    _ -> maybe (fail "Selected branch is missing; checkout main or select another branch") (\target -> dispatch base target cmd) selected

activate :: Profile -> Maybe String -> Aff Unit
activate p selected = do
  file <- liftEffect (N.configDir (I.volumeName p.tool) <#> flip N.pathJoin "active.json")
  case selected of
    Nothing -> liftEffect (N.removeFile file)
    Just name -> liftEffect (PN.writeJson file name)

dispatch :: Runner -> Profile -> Command -> Aff Int
dispatch base p cmd = case cmd of
  OnBranch name nested -> do
    list <- entries p
    st <- state (root p)
    if name == st.branch then dispatch base (root p) nested
    else case A.find (\e -> e.name == name) list of
      Nothing -> fail ("No parallel instance for '" <> name <> "'; create it with branch NAME")
      Just e -> dispatch base (p {tool = e.tool}) nested
  Branch o -> branch base p o
  Checkout o -> locked p do
    when (I.isInstance p.tool) $ fail "A parallel instance stays on its own branch; checkout operates on the parent sandbox"
    list <- entries p
    if A.any (\e -> e.name == o.name) list then do
      when o.create $ fail "Branch already exists"
      activate p (Just o.name)
      say ("Selected parallel branch '" <> o.name <> "'; all servers keep running") $> 0
    else do
      activate p Nothing
      checkoutBase base p cmd o list
  Destroy o -> locked p do
    confirmed <- if o.yes then pure true else do
      tty <- liftEffect N.isTty
      unless tty $ fail "Not a terminal; pass --yes to confirm"
      N.confirm "Destroy this sandbox and its data? [y/N] "
    if not confirmed then pure 1 else if I.isInstance p.tool then remove base p
    else do
      list <- entries p
      when (not (A.null list)) do
        parent <- state p
        when (parent.os == "linux") Engine.ensureEngine
      for_ list \e -> do
        let child = p {tool = e.tool}
        void $ stopInstance base child
        st <- state child
        if st.os == "linux" then do
          Engine.removeContainer child
          void $ Zfs.detach (Zfs.target (I.volumeName p.tool) (Just st.branch)) Docker.machineName
        else BSD.unmount child st
        liftEffect (State.clear e.tool)
        remaining <- entries p
        saveEntries p (A.filter (\other -> other.tool /= e.tool) remaining)
      saveEntries p []
      activate p Nothing
      base p (Destroy {yes: true})
  Start o -> do
    list <- entries p
    when (I.isInstance p.tool || not (A.null list)) do
      saved <- state p
      for_ o.os \os -> when (osName os /= saved.os) $ fail "A branch must keep its recorded guest OS"
      for_ o.version \version -> when (version /= saved.version) $ fail "A branch must keep its recorded database/OS version"
    for_ o.port \n -> do
      unless (n > 0 && n <= 65535) $ fail "Port must be between 1 and 65535"
      used <- reserved p p.tool
      when (A.elem n used) $ fail ("Port " <> show n <> " is reserved by another branch")
    for_ o.branch \name -> when (A.any (\e -> e.name == name && e.tool /= p.tool) list) $ fail "That branch already has its own server; use --branch NAME start"
    if I.isInstance p.tool then locked p (startInstance base p o)
    else if A.null list then base p cmd else locked p do
      st <- state p
      if st.os == "linux" then base p cmd else do
        m <- BSD.machine p
        for_ o.port \n -> when (n /= st.port) $ fail "Change the parent BSD port before creating parallel branches"
        for_ o.cpus \_ -> fail "Resize the parent BSD VM after removing its parallel branches"
        for_ o.mem \_ -> fail "Resize the parent BSD VM after removing its parallel branches"
        if m.running then BSD.start p st $> 0 else do
          result <- base p cmd
          for_ list \e -> when e.running (void (startInstance base (p {tool = e.tool}) emptyStart))
          pure result
  Stop -> do
    list <- entries p
    if I.isInstance p.tool then locked p (stopInstance base p)
    else if A.null list then base p cmd else do
      st <- state p
      if st.os == "linux" then base p cmd else locked p (BSD.stop p st $> 0)
  Status -> do
    list <- entries p
    if A.null list then base p Status else do
      st <- state p
      if st.os == "linux" then base p Status else bsdCommand p st Status
  _ | I.isInstance p.tool -> do
    st <- state p
    if st.os == "linux" then base p cmd else bsdCommand p st cmd
  _ -> base p cmd

startInstance :: Runner -> Profile -> StartOpts -> Aff Int
startInstance base p o = do
  st <- state p
  up <- if st.os == "linux" then Engine.isRunning p else BSD.running p st
  let requestedPort = fromMaybe st.port o.port
  when (hasPort p st && (not up || requestedPort /= st.port)) $ waitFree requestedPort 40
  for_ o.branch \name -> when (name /= st.branch) $ fail "Parallel instances cannot change their mounted branch"
  if st.os == "linux" then do
    result <- base p (Start (o {branch = Just st.branch}))
    when (result == 0) (mark p true)
    pure result
  else do
    let next = st {port = fromMaybe st.port o.port}
    when (next.port /= st.port) do
      when (next.port == p.guestPort) $ fail "The parent server already uses that BSD guest port"
      free <- available p next next.port
      unless free $ fail "Requested branch port is in use"
      BSD.stop p st
    BSD.start p next
    liftEffect (State.save p.tool next)
    mark p true
    say ("Branch '" <> st.branch <> "' is ready: " <> BSD.endpoint p next) $> 0
stopInstance :: Runner -> Profile -> Aff Int
stopInstance base p = do
  st <- state p
  result <- if st.os == "linux" then base p Stop else BSD.stop p st *> say "stopped" $> 0
  when (result == 0) (mark p false)
  pure result

branch :: Runner -> Profile -> BranchOpts -> Aff Int
branch base p o = case o.name, o.arg of
  Just "ls", _ -> branch base p (o {name = Nothing, arg = Nothing})
  Just "list", _ -> branch base p (o {name = Nothing, arg = Nothing})
  Just "rm", Just name -> branch base p (o {name = Just name, arg = Nothing, delete = true})
  Just "delete", Just name -> branch base p (o {name = Just name, arg = Nothing, delete = true})
  _, Just _ -> base p (Branch o)
  Nothing, _ -> do
    result <- base p (Branch o)
    list <- entries p
    for_ list \e -> do
      let child = p {tool = e.tool}
      st <- state child
      up <- if st.os == "linux" then Engine.isRunning child else BSD.running child st
      color <- liftEffect N.colorOutput
      let status = if up then (if color then N.ansi "38;2;0;255;195" "RUNNING" else "RUNNING") else "STOPPED"
      say ("  " <> (if color && e.tool == p.tool then N.ansi "38;2;0;255;195" e.name else e.name) <> "  " <> status <> (if hasPort p st then "  127.0.0.1:" <> show st.port else "  embedded") <> "  [--branch " <> e.name <> "]")
    pure result
  Just name, Nothing | o.delete -> locked p do
    list <- entries p
    case A.find (\e -> e.name == name) list of
      Just e -> remove base (p {tool = e.tool})
      Nothing -> do
        parent <- state (root p)
        when (name == parent.branch) $ fail "That dataset is in use by the parent server; checkout another parent branch first"
        base (root p) (Branch o)
  Just name, Nothing -> locked p do
    unless (I.validName name) $ fail "Invalid branch name; use up to 64 letters, digits, '.', '_' or '-', starting with a letter or digit"
    parent <- state p
    vol <- volume p
    list <- entries p
    when (A.any (\b -> b.name == name) vol.branches || A.any (\e -> e.name == name) list) $ fail "Branch already exists"
    let from = fromMaybe parent.branch o.from
    unless (from == "main" || A.any (\b -> b.name == from) vol.branches) $ fail "Source branch does not exist"
    source <- case A.find (\e -> e.name == from) list of
      Just e -> state (p {tool = e.tool})
      Nothing -> state (root p)
    let child = p {tool = I.instanceName p.tool name}
    used <- reserved p ""
    port <- if hasPort p source then selectPort (used <> if source.os == "linux" then [] else [p.guestPort]) (available p source) o.port (if source.port > 0 && source.port < 65535 then source.port + 1 else p.guestPort + 1) else do
      for_ o.port \_ -> fail "This database mode does not expose a server port"
      pure 0
    when (source.os == "linux") Engine.ensureEngine
    -- Branching uses the pool's current holder. In particular, BSD never
    -- imports the same pool into a second VM.
    void $ Zfs.branch vol.name name (Just from)
    let next = source {branch = name, port = port}
    liftEffect (State.save child.tool next)
    saveEntries p (list <> [{name, tool: child.tool, running: false}])
    say ("Starting parallel branch '" <> name <> "' from '" <> from <> "' ...")
    -- Keep metadata and clone after a startup error: --branch NAME start can
    -- recover without destroying either the source or newly written data.
    startInstance base child emptyStart

remove :: Runner -> Profile -> Aff Int
remove base p = do
  st <- state p
  when (st.os == "linux") Engine.ensureEngine
  void $ stopInstance base p
  if st.os == "linux" then do
    Engine.removeContainer p
    void $ Zfs.detach (Zfs.target (I.volumeName p.tool) (Just st.branch)) Docker.machineName
  else BSD.unmount p st
  Zfs.destroy [Zfs.target (I.volumeName p.tool) (Just st.branch)] false
  liftEffect (State.clear p.tool)
  list <- entries p
  saveEntries p (A.filter (\e -> e.tool /= p.tool) list)
  file <- liftEffect (N.configDir (I.volumeName p.tool) <#> flip N.pathJoin "active.json")
  active <- liftEffect (N.readJson file) <#> toMaybe
  when (active == Just st.branch) (activate p Nothing)
  say ("Deleted parallel branch '" <> st.branch <> "'") $> 0

bsdCommand :: Profile -> State -> Command -> Aff Int
bsdCommand p st = case _ of
  Status -> do
    up <- BSD.running p st
    color <- liftEffect N.colorOutput
    let paint text = if color then N.ansi "38;2;0;255;195" text else text
    say ("branch " <> paint st.branch <> "  " <> (if up then paint "RUNNING" else "STOPPED") <> (if st.port > 0 then "  127.0.0.1:" <> show st.port else "  embedded")) $> 0
  Url -> say (BSD.endpoint p st) $> 0
  Exec o -> do
    m <- BSD.machine p
    box <- B.get m.id
    Sandbox.execAttached o.tty o.command box
  Shell -> BSD.machine p >>= B.get <<< _.id >>= Sandbox.shell
  Logs _ -> do
    m <- BSD.machine p
    box <- B.get m.id
    r <- B.exec ["sh", "-c", "cat " <> shellQuote (BSD.directory p st <> "/sbx-server.log")] box
    say r.stdout $> r.exitCode
  Client -> BSD.client p st []
  _ -> fail "Use status, url, start, stop, exec, log, or the database client for this BSD branch"

checkoutBase :: Runner -> Profile -> Command -> {name :: String, create :: Boolean} -> Array Entry -> Aff Int
checkoutBase base p cmd o list = do
    if A.null list then base p cmd else do
      st <- state p
      if st.branch == o.name && not o.create then say ("Selected branch '" <> o.name <> "'") $> 0
      else if st.os == "linux" then base p cmd else do
        vol <- volume p
        when o.create $ void $ Zfs.branch vol.name o.name (Just st.branch)
        unless (o.create || A.any (\b -> b.name == o.name) vol.branches || o.name == "main") $ fail "Unknown branch"
        wasRunning <- BSD.running p st
        when wasRunning $ BSD.stop p st
        m <- BSD.machine p
        void $ Zfs.detach (Zfs.target vol.name (Just st.branch)) m.id
        void $ Zfs.attachAt (Zfs.target vol.name (Just o.name)) m.id (Just (BSD.directory p st))
        let next = st {branch = o.name}
        liftEffect (State.save p.tool next)
        when wasRunning $ BSD.start p next
        say ("Switched to branch '" <> o.name <> "'") $> 0


mark :: Profile -> Boolean -> Aff Unit
mark p up = do
  list <- entries p
  saveEntries p (map (\e -> if e.tool == p.tool then e {running = up} else e) list)

waitFree :: Int -> Int -> Aff Unit
waitFree port attempts = do
  free <- Port.isFreeOn "127.0.0.1" port
  unless free $ if attempts == 0 then fail ("Host port " <> show port <> " is in use")
    else delay (Milliseconds 500.0) *> waitFree port (attempts - 1)

available :: Profile -> State -> Int -> Aff Boolean
available p st candidate = do
  free <- Port.isFreeOn "127.0.0.1" candidate
  if not free || st.os == "linux" then pure free else do
    m <- BSD.machine p
    if not m.running then pure true else do
      box <- B.get m.id
      probe <- B.exec ["nc", "-z", "-w", "1", "127.0.0.1", show candidate] box
      pure (probe.exitCode /= 0)
