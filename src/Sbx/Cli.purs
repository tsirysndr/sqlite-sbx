-- | The command line, parsed with optparse. Every sandbox tool shares this
-- | module; the profile only changes names in the help text.
module Sbx.Cli
  ( Command(..)
  , StartOpts
  , BranchOpts
  , MigrateCmd(..)
  , parseCommand
  ) where

import Prelude
import Control.Alt ((<|>))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (fold)
import Data.Maybe (Maybe(..), maybe, optional)
import Effect (Effect)
import Options.Applicative (Parser, ReadM, argument, command, commandGroup, customExecParser, eitherReader, footer, forwardOptions, fullDesc, header, help, helper, hidden, info, infoOption, int, long, many, metavar, option, prefs, progDesc, short, showHelpOnEmpty, strArgument, strOption, subparser, switch, value)
import Sbx.Profile (Os, Profile, parseOs)

type StartOpts =
  { os :: Maybe Os
  , version :: Maybe String
  , port :: Maybe Int
  , user :: Maybe String
  , password :: Maybe String
  , db :: Maybe String
  , cpus :: Maybe Int
  , mem :: Maybe Int
  , branch :: Maybe String
  , size :: Maybe String
  }

type BranchOpts = { name :: Maybe String, arg :: Maybe String, delete :: Boolean, from :: Maybe String }

data Command
  = Start StartOpts
  | Stop
  | Status
  | Shell
  | Logs { follow :: Boolean, boot :: Boolean }
  | Branch BranchOpts
  | Checkout { name :: String, create :: Boolean }
  | Url
  | Client
  | Fancy
  | Studio { port :: Int, host :: String }
  | Drizzle (Array String)
  | Doctor
  | Destroy { yes :: Boolean }
  | Migrate MigrateCmd
  | Tool (Array String)
  | Setup

-- | The migration workflow (pgroll's), with the sandbox URL and the
-- | migrations directory filled in.
data MigrateCmd
  = MigrateInit
  | MigrateNew { name :: String, empty :: Boolean, json :: Boolean }
  | MigrateUp { dir :: Maybe String, keepOpen :: Boolean }
  | MigrateStart { file :: String, complete :: Boolean }
  | MigrateComplete
  | MigrateRollback
  | MigrateStatus
  | MigratePull { dir :: Maybe String }
  | MigrateBaseline { version :: String, dir :: Maybe String }

osReader :: ReadM Os
osReader = eitherReader \s -> maybe (Left ("expected linux, freebsd or netbsd, got '" <> s <> "'")) Right (parseOs s)

startP :: Profile -> Parser Command
startP p = ado
  os <- optional $ argument osReader $ fold
    [ metavar "linux|freebsd|netbsd", help "Guest OS (default: linux)" ]
  version <- optional $ strArgument $ fold
    [ metavar "VERSION", help ("Linux: image tag, e.g. " <> p.defaultTag <> " or " <> p.defaultTag <> "-alpine, or a full image reference (default: " <> p.defaultTag <> "). FreeBSD/NetBSD: OS release, e.g. 15.1 or 10.1 (default: latest)") ]
  port <- optional $ option int $ fold
    [ long "port", short 'p', metavar "PORT", help ("Host port forwarded to " <> p.product <> " (default: " <> show p.guestPort <> ")") ]
  user <- credential "user" ("Superuser name (default: " <> p.defaults.user <> ")")
  password <- credential "password" ("Its password (default: " <> p.defaults.password <> ")")
  db <- optional $ strOption $ fold
    [ long "db", metavar "NAME", help ("Database created on first start (default: " <> p.defaults.db <> ")") ]
  cpus <- optional $ option int $ fold [ long "cpus", metavar "N", help "vCPUs (default: 2)" ]
  mem <- optional $ option int $ fold [ long "mem", metavar "MIB", help "Guest RAM in MiB (default: 1024)" ]
  branch <- optional $ strOption $ fold
    [ long "branch", short 'b', metavar "BRANCH", help "Data branch to mount (default: the current one, main at first)" ]
  size <- optional $ strOption $ fold
    [ long "size", metavar "SIZE", help "Data volume size when it is created, e.g. 10G (sparse; default: 10G)" ]
  in Start { os, version, port, user, password, db, cpus, mem, branch, size }
  where
  credential name doc
    | p.hasCredentials = optional $ strOption $ fold [ long name, metavar (if name == "user" then "NAME" else "SECRET"), help doc ]
    | otherwise = pure Nothing

logsP :: Parser Command
logsP = ado
  follow <- switch $ fold [ long "follow", short 'f', help "Keep streaming the console" ]
  boot <- switch $ fold [ long "boot", help "bsdkrun's own boot log instead of the guest console" ]
  in Logs { follow, boot }

branchP :: Parser Command
branchP = ado
  delete <- switch $ fold [ long "delete", short 'd', help "Delete NAME instead of creating it" ]
  from <- optional $ strOption $ fold [ long "from", metavar "BRANCH", help "Branch to fork from (default: the current one)" ]
  name <- optional $ strArgument $ fold [ metavar "NAME", help "Branch to create (or delete with -d). Without it, list branches. Also: `ls`, `rm NAME`" ]
  arg <- optional $ strArgument $ fold [ metavar "ARG", help "The branch for `rm` / `delete`" ]
  in Branch { name, arg, delete, from }

checkoutP :: Parser Command
checkoutP = ado
  create <- switch $ fold [ long "create", short 'b', help "Create NAME from the current branch first" ]
  name <- strArgument $ fold [ metavar "BRANCH", help "Branch to mount as the data directory" ]
  in Checkout { name, create }

studioP :: Parser Command
studioP = ado
  port <- option int $ fold [ long "port", metavar "PORT", value 4983, help "Port Drizzle Studio's server listens on (default: 4983)" ]
  host <- strOption $ fold [ long "host", metavar "HOST", value "127.0.0.1", help "Address it binds (default: 127.0.0.1)" ]
  in Studio { port, host }

destroyP :: Parser Command
destroyP = ado
  yes <- switch $ fold [ long "yes", short 'y', help "Do not ask for confirmation" ]
  in Destroy { yes }

migrateP :: String -> Parser Command
migrateP dir = Migrate <$> subparser
  ( fold
      [ command "init" $ info (pure MigrateInit) $ progDesc "Initialise the migration tool's schema in the sandbox database"
      , command "new" $ info (helper <*> newP) $ progDesc ("Create a migration file in " <> dir <> "/ (interactive unless --empty)")
      , command "up" $ info (helper <*> upP) $ progDesc ("Apply the outstanding migrations from " <> dir <> "/ and complete them")
      , command "start" $ info (helper <*> startMP) $ progDesc "Start one migration file: old and new schema versions coexist until `complete`"
      , command "complete" $ info (pure MigrateComplete) $ progDesc "Complete the migration in progress"
      , command "rollback" $ info (pure MigrateRollback) $ progDesc "Roll back the migration in progress"
      , command "status" $ info (pure MigrateStatus) $ progDesc "Show the current schema version and migration state"
      , command "pull" $ info (helper <*> pullP) $ progDesc ("Write the sandbox's migration history to " <> dir <> "/")
      , command "baseline" $ info (helper <*> baselineP) $ progDesc "Record the current schema as a baseline migration VERSION"
      ]
  )
  where
  dirArg = optional $ strArgument $ fold [ metavar "DIR", help ("Migrations directory (default: " <> dir <> ")") ]
  newP = ado
    name <- strArgument $ fold [ metavar "NAME", help "Migration name, e.g. add_users" ]
    empty <- switch $ fold [ long "empty", short 'e', help "Write an empty migration instead of asking for operations" ]
    json <- switch $ fold [ long "json", help "JSON instead of YAML" ]
    in MigrateNew { name, empty, json }
  upP = ado
    dir' <- dirArg
    keepOpen <- switch $ fold [ long "keep-open", help "Leave the last migration started but not completed" ]
    in MigrateUp { dir: dir', keepOpen }
  startMP = ado
    file <- strArgument $ fold [ metavar "FILE", help "Migration file" ]
    complete <- switch $ fold [ long "complete", short 'c', help "Complete it right away" ]
    in MigrateStart { file, complete }
  pullP = ado
    dir' <- dirArg
    in MigratePull { dir: dir' }
  baselineP = ado
    version <- strArgument $ fold [ metavar "VERSION", help "Baseline version name, e.g. 01_initial" ]
    dir' <- dirArg
    in MigrateBaseline { version, dir: dir' }

commands :: Profile -> Parser Command
commands p = case p.migrations of
  Nothing -> base
  Just m -> base <|> migrationCommands m
  where
  base = subparser
    ( fold
        [ command "start" $ info (helper <*> startP p) $ fold
            [ progDesc ("Start the sandbox, creating the VM and its data volume on first run")
            , footer ("Credentials and the database are set when a data branch is first initialised; later starts reuse them. " <> p.tool <> " start linux " <> p.defaultTag <> "-alpine, " <> p.tool <> " start freebsd 15.1")
            ]
        , command "stop" $ info (pure Stop) $ progDesc "Stop the VM (data stays on its branch)"
        , command "status" $ info (pure Status) $ progDesc "Show the VM, the mounted branch and the connection URL"
        , command "ssh" $ info (pure Shell) $ progDesc "Open a shell in the VM (alias: shell)"
        , command "log" $ info (helper <*> logsP) $ progDesc "Show the VM console log, -f to follow (alias: logs)"
        , command "branch" $ info (helper <*> branchP) $ fold
            [ progDesc "List data branches, create one (copy-on-write) or delete one"
            , footer ("Like git: `" <> p.tool <> " branch` (or `branch ls`) lists, `" <> p.tool <> " branch NAME` forks the current branch, `" <> p.tool <> " branch -d NAME` (or `branch rm NAME`) deletes, `" <> p.tool <> " checkout NAME` switches.")
            ]
        , command "checkout" $ info (helper <*> checkoutP) $ progDesc "Switch the data directory to BRANCH, -b to create it first (alias: switch)"
        , command p.clientName $ info (pure Client) $ progDesc ("Open " <> p.clientName <> " on the sandbox database")
        , command p.fancy.name $ info (pure Fancy) $ progDesc ("Open " <> p.fancy.name <> " (auto-completion, syntax highlighting) on the sandbox database")
        , command "url" $ info (pure Url) $ progDesc "Print the connection URL"
        , command "studio" $ info (helper <*> studioP) $ progDesc "Open Drizzle Studio on the sandbox database"
        , command "drizzle" $ info (helper <*> (Drizzle <<< Array.fromFoldable <$> many (strArgument (metavar "ARGS...")))) $ fold
            [ progDesc "Run drizzle-kit with DATABASE_URL pointing at the sandbox"
            , footer (p.tool <> " drizzle push, " <> p.tool <> " drizzle generate, " <> p.tool <> " drizzle migrate. Your drizzle.config.ts can read process.env.DATABASE_URL; without one, a config for the sandbox is supplied.")
            , forwardOptions
            ]
        , command "doctor" $ info (pure Doctor) $ progDesc ("Check bsdkrun, the hypervisor, Node, drizzle-kit, " <> p.fancy.name <> maybe "" (\m -> " and " <> m.name) p.migrations)
        , command "destroy" $ info (helper <*> destroyP) $ progDesc "Remove the VM and the data volume with every branch (asks first)"
        ]
    )
    <|> subparser
      ( fold
          [ command "shell" $ info (pure Shell) $ progDesc "Alias of ssh"
          , command "logs" $ info (helper <*> logsP) $ progDesc "Alias of log"
          , command "switch" $ info (helper <*> checkoutP) $ progDesc "Alias of checkout"
          , commandGroup "Aliases:"
          , hidden
          ]
      )
  migrationCommands m = subparser
    ( fold
        [ command "migrate" $ info (helper <*> migrateP m.dir) $ fold
            [ progDesc ("Schema migrations with " <> m.name <> ": init, new, up, start, complete, rollback, status, pull, baseline")
            , footer ("Pairs with branches: `" <> p.tool <> " checkout -b try-migration`, `" <> p.tool <> " migrate up`, look around, `" <> p.tool <> " checkout main`.")
            ]
        , command m.name $ info (helper <*> (Tool <<< Array.fromFoldable <$> many (strArgument (metavar "ARGS...")))) $ fold
            [ progDesc ("Run " <> m.name <> " with the sandbox URL (any " <> m.name <> " arguments)")
            , forwardOptions
            ]
        , command "setup" $ info (pure Setup) $ progDesc ("Install " <> m.name <> " on this host (Homebrew, or its release binary into ~/.local/bin) and initialise it in the sandbox")
        , commandGroup "Migrations:"
        ]
    )

parseCommand :: Profile -> String -> Effect Command
parseCommand p version = customExecParser (prefs showHelpOnEmpty) $ info (helper <*> versionOption <*> commands p) $ fold
  [ fullDesc
  , header (p.tool <> " — " <> p.product <> " in a bsdkrun microVM, with branchable data")
  , progDesc ("One " <> p.product <> " server per sandbox, running in a lightweight VM. Its data directory is a ZFS branch: fork it copy-on-write, switch between branches, throw them away. Drizzle Studio and drizzle-kit are wired to it.")
  ]
  where
  versionOption = infoOption (p.tool <> " " <> version) $ fold [ long "version", help "Show the version" ]
