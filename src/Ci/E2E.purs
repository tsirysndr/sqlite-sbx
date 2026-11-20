module Ci.E2E (run, sandboxCli, redact) where

import Prelude
import Ci.Database as Database
import Ci.Common as C
import Ci.Install as Install
import Ci.Native as N
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Foldable (any, for_)
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, bracket, forkAff, killFiber, finally, delay)
import Data.Time.Duration (Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (message, error)
import Effect.Ref as Ref
import Foreign.Object as O
import Node.Process (setExitCode)
import Sbx.App as App
import Sbx.Cli as Cli
import Sbx.Sqlite (profile)

type Context =
  { name :: String, scratch :: String, logDir :: String, log :: String
  , env :: O.Object String, runtime :: String, node :: String, version :: String
  , password :: String, started :: Ref.Ref Boolean, engineWasRunning :: Ref.Ref Boolean
  , occupied :: Ref.Ref (Maybe N.Port), succeeded :: Ref.Ref Boolean
  }

type Options = { allowFailure :: Boolean, secret :: Boolean, timeout :: Int, env :: O.Object String }
defaultOptions :: Options
defaultOptions = { allowFailure: false, secret: false, timeout: 300000, env: O.empty }

redact :: Array String -> Array String
redact args = A.mapWithIndex (\i arg -> if A.index args (i - 1) == Just "--password" then "<redacted>" else arg) args

redactText :: Context -> String -> String
redactText c = S.replaceAll (S.Pattern c.password) (S.Replacement "<redacted>")

record :: Context -> String -> Aff Unit
record c text = liftEffect $ N.appendText c.log (redactText c text <> "\n")
pass :: Context -> String -> Aff Unit
pass c text = liftEffect (Console.error ("PASS: " <> text)) *> record c ("PASS: " <> text)

command :: Context -> Options -> String -> Array String -> Aff N.Result
command c options program args = do
  let label = redactText c (program <> " " <> S.joinWith " " (redact args))
  liftEffect (N.stream ("[e2e] $ " <> label <> "\n"))
  unless options.secret $ record c ("$ " <> label)
  let output chunk = unless options.secret (N.appendText c.log (redactText c chunk) *> N.stream (redactText c chunk))
  heartbeat <- forkAff (waiting label 15)
  result <- finally (killFiber (error "command completed") heartbeat) $
    N.command { program, args, env: O.union options.env c.env, timeout: options.timeout, cwd: "", output }
  C.demand (program <> " failed (" <> show result.code <> ")" <> if options.secret then "" else ": " <> redactText c result.stderr) (options.allowFailure || result.code == 0)
  pure result
  where
  waiting label seconds = do
    delay (Milliseconds 15000.0)
    liftEffect $ N.stream ("[e2e] still running (" <> show seconds <> "s): " <> label <> "\n")
    waiting label (seconds + 15)

cliWith :: Context -> Options -> Array String -> Aff N.Result
cliWith c options args = command c options c.node ([ "bin/ci.js", "sandbox-cli", c.name ] <> args)
cli :: Context -> Array String -> Aff String
cli c args = S.trim <<< _.stdout <$> cliWith c defaultOptions args
runtime :: Context -> Array String -> Aff String
runtime c args = _.stdout <$> command c defaultOptions c.runtime args

query :: Context -> String -> Aff String
query c = queryAt c []

queryAt :: Context -> Array String -> String -> Aff String
queryAt c selected sql = do
  uri <- cliWith c (defaultOptions { secret = true }) (selected <> [ "url" ])
  rows <- Database.query { url: S.trim uri.stdout, sql }
  pure (S.joinWith "\n" (map (S.joinWith ",") rows))

assertEqual :: String -> String -> Aff Unit
assertEqual expected actual = C.demand ("Expected " <> show expected <> ", got " <> show actual) (actual == expected)

freePort :: Aff Int
freePort = bracket N.reservePort (N.closePort <<< _.handle) (pure <<< _.port)

setup :: Aff Context
setup = do
  C.prepareRuntime
  name <- ("sqlite-sbx-e2e-" <> _) <$> liftEffect (N.randomHex 6)
  password <- ("e2e-" <> _) <$> liftEffect (N.randomHex 24)
  scratch <- liftEffect (N.tempDir "sqlite-sbx-e2e-")
  logDir <- C.fallback "SQLITE_SBX_E2E_LOG_DIR" ".fluentci/test-logs" >>= liftEffect <<< N.resolve
  let log = logDir <> "/e2e.log"
  liftEffect (N.mkdir logDir *> N.writeText log "")
  runtimePath <- C.bsdkrun
  node <- liftEffect N.node
  version <- C.projectVersion
  started <- liftEffect (Ref.new false)
  engineWasRunning <- liftEffect (Ref.new true)
  occupied <- liftEffect (Ref.new Nothing)
  succeeded <- liftEffect (Ref.new false)
  pure { name, scratch, logDir, log, node, version, password, started, engineWasRunning, occupied, succeeded
       , runtime: runtimePath
       , env: O.fromFoldable [ "XDG_CONFIG_HOME" /\ (scratch <> "/config"), "NO_COLOR" /\ "1", "BSDKRUN_NO_AUTO_INSTALL" /\ "1" ] }

body :: Context -> Aff Unit
body c = do
  before <- runtime c [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix
  wasRunning <- C.fromEither (C.boolField "running" before)
  liftEffect (Ref.write wasRunning c.engineWasRunning)
  void $ runtime c [ "probe" ]
  machines <- runtime c [ "ps", "--all", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  volumes <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  let named item = C.stringField "name" item == Right c.name
  C.demand "E2E sandbox already exists" (not (any named machines || any named volumes))
  binary <- liftEffect (N.resolve "dist/sqlite-sbx")
  result <- command c defaultOptions binary [ "--version" ]
  assertEqual ("sqlite-sbx " <> c.version) (S.trim result.stdout)
  guest <- C.fallback "SBX_E2E_OS" "linux"
  C.demand "Expected linux, freebsd or netbsd" (A.elem guest ["linux", "freebsd", "netbsd"])
  port <- freePort
  liftEffect (Ref.write true c.started)
  void $ cliWith c (defaultOptions { timeout = 600000 })
    ([ "start", guest ] <> (if guest == "linux" then ["latest"] else ["--mem", "2048"]) <> [ "--port", show port, "-d" ] <> [])
  query c "SELECT 42;" >>= assertEqual "42"
  pass c "host libSQL client reaches the server through the forwarded HTTP port"
  void $ query c "CREATE TABLE e2e_values (n INTEGER);"
  void $ query c "INSERT INTO e2e_values VALUES (42);"
  when (guest == "linux" && not wasRunning) do
    Install.verifyDriver c.runtime
    void $ runtime c [ "docker", "stop" ]
    void $ cli c [ "start", "-d" ]
    Install.verifyDriver c.runtime
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    pass c "normal startup creates an overlay/ext4 engine and preserves it across VM restart"
  void $ cli c [ "branch", "feature" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ queryAt c ["--branch", "feature"] "UPDATE e2e_values SET n=7;"
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "branch", "nested", "--from", "feature" ]
  queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "checkout", "feature" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "checkout", "main" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "stop" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "start", "-d" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "--branch", "feature", "stop" ]
  queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  when (guest /= "linux") do
    void $ runtime c ["stop", c.name]
    void $ cli c ["start", "-d"]
    queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
    stoppedFork <- cli c ["--branch", "feature", "status"]
    C.demand "A stopped fork restarted with the BSD VM" (S.contains (S.Pattern "STOPPED") stoppedFork)
  void $ cli c [ "--branch", "feature", "start", "-d" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "branch", "-d", "nested" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "branch", "-d", "feature" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  pass c "parallel containers, nested forks, focus changes, independent stops and ZFS isolation"

  when (guest == "linux") do
    void $ cli c [ "stop" ]
    stopped <- cli c [ "status" ]
    C.demand "Sandbox did not stop" (S.contains (S.Pattern "STOPPED") stopped)
    collisionPort <- N.reservePort
    liftEffect (Ref.write (Just collisionPort.handle) c.occupied)
    collision <- cliWith c (defaultOptions { allowFailure = true }) [ "start", "--port", show collisionPort.port, "-d" ]
    C.demand "Occupied port was accepted" (collision.code /= 0)
    N.closePort collisionPort.handle
    liftEffect (Ref.write Nothing c.occupied)
    nextPort <- freePort
    void $ cli c [ "start", "--port", show nextPort, "-d" ]
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    void $ cli c [ "stop" ]
    void $ cli c [ "start", "-d" ]
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    pass c "occupied ports fail clearly; port changes and stop/start preserve data"
  liftEffect (Ref.write true c.succeeded)

cleanup :: Context -> Aff Unit
cleanup c = do
  result <- attempt do
    occupied <- liftEffect (Ref.read c.occupied)
    for_ occupied N.closePort
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "ps", "--all", "--json" ]
    -- Capture the actual post-restart mount/driver state, not just whether
    -- the host data.img file exists. No state files or credentials are copied.
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "docker", "status", "--json" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/mounts" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "stat", "-f", "-c", "%T", "/var/lib/docker" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/1/limits" ]
    started <- liftEffect (Ref.read c.started)
    when started do
      void $ cliWith c (defaultOptions { allowFailure = true, timeout = 15000 }) [ "log" ]
      void $ cliWith c (defaultOptions { timeout = 120000 }) [ "destroy", "--yes" ]
    after <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
    C.demand "E2E data volume leaked" (not (any (\j -> C.stringField "name" j == Right c.name) after))
    wasRunning <- liftEffect (Ref.read c.engineWasRunning)
    unless wasRunning do
      running <- runtime c [ "docker", "ps", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
      when (A.null running) $ void $ runtime c [ "docker", "stop" ]
    pass c "temporary sandbox removed; existing engine/services preserved"
  succeeded <- liftEffect (Ref.read c.succeeded)
  let ok = succeeded && either (const false) (const true) result
  liftEffect do
    N.writeText (c.logDir <> "/result.json") $ J.stringify $ J.fromObject $ O.fromFoldable
      [ "passed" /\ J.fromBoolean ok, "sandbox" /\ J.fromString c.name ]
    N.remove c.scratch
  case result of
    Left err -> record c ("CLEANUP FAILED: " <> message err) *> throwError err
    Right _ -> pure unit

run :: Aff Unit
run = bracket setup cleanup \c -> do
  result <- attempt (body c)
  case result of
    Left err -> record c ("FAIL: " <> message err) *> throwError err
    Right _ -> pure unit

sandboxCli :: String -> Array String -> Aff Unit
sandboxCli name args = do
  C.demand "Missing isolated E2E sandbox name" (C.matches "^sqlite-sbx-e2e-[a-f0-9]{12}$" name)
  version <- C.projectVersion
  let isolated = profile { tool = name }
  cmd <- liftEffect (N.setArgs args *> Cli.parseCommand isolated version)
  App.run isolated cmd >>= liftEffect <<< setExitCode
