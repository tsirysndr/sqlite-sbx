-- | Independent BSD database processes over separate dataset mountpoints.
module Sbx.BsdServer (machine, directory, script, start, stop, running, unmount, client, endpoint) where
import Prelude
import Bsdkrun as B
import Bsdkrun.Port as Port
import Data.Either (Either(..))
import Bsdkrun.Sandbox as Sandbox
import Bsdkrun.Types (SandboxInfo)
import Bsdkrun.Zfs as Zfs
import Control.Monad.Error.Class (throwError)
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Nullable (toMaybe)
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, attempt, delay)
import Effect.Exception (error)
import Effect.Class (liftEffect)
import Sbx.Native as N
import Sbx.Identity as I
import Sbx.ParallelNative as PN
import Sbx.Profile (Profile, Os(..), parseOs, shellQuote, withBsdPath)
import Sbx.State (State)

machine :: Profile -> Aff SandboxInfo
machine p = B.list true >>= maybe (throwError (error "Parent BSD VM is missing; start it first")) pure <<< A.find (\m -> toMaybe m.name == Just (I.volumeName p.tool))
directory :: Profile -> State -> String
directory p st = if I.isInstance p.tool then "/mnt/" <> p.tool else p.dataDir (fromMaybe FreeBSD (parseOs st.os))
port :: Profile -> State -> Int
port p st = if I.isInstance p.tool then st.port else p.guestPort

-- All substituted paths are shell quoted. Credentials are inherited on disk,
-- and never inserted into process arguments or logs to start a fork.
script :: Profile -> State -> String -> String
script p st action =
  let dir = directory p st
      q = shellQuote
      pgUser = if st.os == "netbsd" then "pgsql" else "postgres"
      pgData = dir <> (if st.os == "netbsd" then "/data" else "/data18")
      pg cmd = "su -m " <> pgUser <> " -c " <> q ("PATH=/usr/local/bin:/usr/pkg/bin:$PATH; pg_ctl -D " <> q pgData <> " " <> cmd)
      pid = dir <> "/sbx-branch.pid"
      pgStatus = "test -f " <> q (pgData <> "/postmaster.pid") <> " && [ \"$(sed -n '2p' " <> q (pgData <> "/postmaster.pid") <> ")\" = " <> q pgData <> " ] && " <> pg "status"
      mysqlStatus = "test -s " <> q pid <> " && ps -ww -p \"$(cat " <> q pid <> ")\" -o args= | grep -F -- " <> q ("--datadir=" <> dir)
  in "set -eu\nexport PATH=/usr/local/bin:/usr/local/sbin:/usr/local/libexec:/usr/pkg/bin:/usr/pkg/sbin:/usr/pkg/libexec:$PATH\n" <> case p.product of
    "PostgreSQL" -> case action of
      "status" -> pgStatus
      "stop" -> "if (" <> pgStatus <> ") >/dev/null 2>&1; then " <> pg "-m fast -w stop" <> "; fi"
      _ -> "if ! (" <> pgStatus <> "); then if [ -f " <> q (pgData <> "/postmaster.pid") <> " ] && [ \"$(sed -n '2p' " <> q (pgData <> "/postmaster.pid") <> ")\" != " <> q pgData <> " ]; then rm -f " <> q (pgData <> "/postmaster.pid") <> "; fi; " <> pg ("-l " <> q (dir <> "/sbx-server.log") <> " -o " <> q ("-p " <> show (port p st) <> " -h 0.0.0.0 -k " <> dir) <> " -w start") <> "; fi"
    "MariaDB" -> case action of
      "status" -> if I.isInstance p.tool then mysqlStatus else (if st.os == "netbsd" then "if [ -x /etc/rc.d/mariadb ]; then /etc/rc.d/mariadb onestatus; else /etc/rc.d/mysqld onestatus; fi" else "service mysql-server onestatus")
      "stop" -> if I.isInstance p.tool then "if " <> mysqlStatus <> "; then kill -TERM \"$(cat " <> q pid <> ")\"; i=0; while " <> mysqlStatus <> "; do i=$((i+1)); [ $i -lt 120 ] || exit 1; sleep 1; done; fi"
        else (if st.os == "netbsd" then "if [ -x /etc/rc.d/mariadb ]; then /etc/rc.d/mariadb onestop; else /etc/rc.d/mysqld onestop; fi" else "service mysql-server onestop")
      _ -> if not (I.isInstance p.tool) then (if st.os == "netbsd" then "if [ -x /etc/rc.d/mariadb ]; then /etc/rc.d/mariadb onestart; else /etc/rc.d/mysqld onestart; fi" else "service mysql-server onestart")
        else "server=$(command -v mariadbd || command -v mysqld); owner=mysql; if [ \"$(uname -s)\" = NetBSD ] && id -u mariadb >/dev/null 2>&1; then owner=mariadb; fi; if ! (" <> mysqlStatus <> "); then chown -R \"$owner:$owner\" " <> q dir <> "; nohup \"$server\" --no-defaults --user=\"$owner\" --datadir=" <> q dir <> " --port=" <> show st.port <> " --bind-address=0.0.0.0 --socket=" <> q (dir <> "/sbx.sock") <> " --pid-file=" <> q pid <> " --log-error=" <> q (dir <> "/sbx-server.log") <> " > /dev/null 2>&1 < /dev/null & fi"
    _ -> "test -d " <> q dir

execute :: Profile -> State -> String -> Aff Boolean
execute p st action = do
  m <- machine p
  if not m.running then pure false else do
    box <- B.get m.id
    r <- B.exec ["sh", "-c", script p st action] box
    pure (r.exitCode == 0)
running :: Profile -> State -> Aff Boolean
running p st | p.product == "DuckDB" = do
  m <- machine p
  vols <- Zfs.list
  pure (m.running && A.any (\v -> v.name == I.volumeName p.tool && A.any (\a -> A.any (\mount -> mount.branch == st.branch && mount.mountpoint == directory p st) a.mounts) v.attachedTo) vols)
running p st = attempt (execute p st "status") <#> case _ of
  Left _ -> false
  Right ok -> ok

endpoint :: Profile -> State -> String
endpoint p st = if p.product == "DuckDB" then "file " <> directory p st <> "/" <> st.db <> ".duckdb in the BSD guest (no server)" else p.url st.version {user: st.user, password: st.password, db: st.db} st.port

forward :: Profile -> State -> Boolean -> Aff Unit
forward p st enabled = when (st.port > 0 && I.isInstance p.tool) do
  m <- machine p
  when m.running $ PN.forward { stateDir: m.stateDir, ip: fromMaybe "192.168.127.2" (toMaybe m.netIp), port: st.port, guestPort: st.port, enabled }

start :: Profile -> State -> Aff Unit
start p st = do
  m <- machine p
  unless m.running do
    box <- B.get m.id
    void (B.start box)
    waitAgent box 180
  void $ Zfs.attachAt (Zfs.target (I.volumeName p.tool) (Just st.branch)) m.id (Just (directory p st))
  up <- running p st
  unless up do
    ok <- execute p st "start"
    unless ok $ throwError (error "BSD branch server failed to start; inspect its sbx-server.log")
    waitReady 120
  -- Idempotent starts retain their existing forward. A restarted VM needs it
  -- exposed again even if a database process has already been restored.
  when (st.port > 0 && I.isInstance p.tool) do
    free <- Port.isFreeOn "127.0.0.1" st.port
    when free (forward p st true)
  where
  waitAgent _ 0 = throwError (error "BSD guest agent did not become ready")
  waitAgent box n = do
    result <- attempt (B.exec ["true"] box)
    let ready = case result of
          Right r -> r.exitCode == 0
          Left _ -> false
    unless ready (delay (Milliseconds 1000.0) *> waitAgent box (n - 1))
  waitReady 0 = throwError (error "BSD branch server did not become ready")
  waitReady n = do
    ready <- execute p st "status"
    unless ready (delay (Milliseconds 1000.0) *> waitReady (n - 1))

stop :: Profile -> State -> Aff Unit
stop p st = do
  m <- machine p
  when m.running do
    ok <- execute p st "stop"
    unless ok $ throwError (error "BSD branch server did not stop cleanly")
    forward p st false
    when (st.port == 0) (unmount p st)
unmount :: Profile -> State -> Aff Unit
unmount p st = do
  m <- machine p
  void $ Zfs.detach (Zfs.target (I.volumeName p.tool) (Just st.branch)) m.id

client :: Profile -> State -> Array String -> Aff Int
client p st extra = do
  m <- machine p
  box <- B.get m.id
  let args = case p.product of
        "PostgreSQL" -> ["sh", "-c", "PGPASSWORD=" <> shellQuote st.password <> " PATH=/usr/local/bin:/usr/pkg/bin:$PATH exec psql -h 127.0.0.1 -p " <> show st.port <> " -U " <> shellQuote st.user <> " -d " <> shellQuote st.db <> " \"$@\"", "psql"] <> extra
        "MariaDB" -> withBsdPath ("mariadb -h 127.0.0.1 -P " <> show st.port <> " -u " <> shellQuote st.user <> " --password=" <> shellQuote st.password <> " " <> shellQuote st.db)
        _ -> ["sh", "-c", "PATH=/usr/local/bin:/usr/pkg/bin:$PATH; exec duckdb " <> shellQuote (directory p st <> "/" <> st.db <> ".duckdb") <> " \"$@\"", "duckdb"] <> extra
  tty <- liftEffect N.isTty
  Sandbox.execAttached tty args box
