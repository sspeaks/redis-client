module CommandHelp
  ( publicModes
  , renderCommandHelp
  , renderReadmeCliReference
  , helpFlag
  ) where

import           AppConfig        (benchDuration, benchOperation,
                                   defaultRunState, keySize, muxCount,
                                   numConnections, pipelineBatchSize,
                                   tunnelMode, valueSize)
import           CredentialConfig (passwordEnvironmentVariable,
                                   passwordFileEnvironmentVariable)
import           Data.List        (intercalate)
import           Data.Maybe       (fromMaybe)

data ModeDoc = ModeDoc
  { modeName    :: String
  , modePurpose :: String
  , modeNotes   :: String
  }

data OptionDoc = OptionDoc
  { optionFlags   :: String
  , optionApplies :: String
  , optionDetails :: String
  }

data EnvironmentDoc = EnvironmentDoc
  { environmentName    :: String
  , environmentDetails :: String
  }

helpFlag :: String
helpFlag = "--help"

publicModes :: [String]
publicModes = map modeName modeDocs

renderCommandHelp :: String
renderCommandHelp =
  unlines $
    [ "Usage:"
    , "  redis-client [mode] [OPTION...]"
    , ""
    , "Modes:"
    ]
      ++ map renderModeLine modeDocs
      ++ [ ""
         , "Options:"
         ]
      ++ renderAlignedTable
           [("Option", 34), ("Applies to", 28), ("Details", 0)]
           [[optionFlags option, optionApplies option, optionDetails option] | option <- optionDocs]
      ++ [ ""
         , "Environment variables:"
         ]
      ++ renderAlignedTable
           [("Name", 28), ("Details", 0)]
           [[environmentName env, environmentDetails env] | env <- environmentDocs]
      ++ [ ""
         , "Flush confirmation:"
         , "  Standalone target: redis://HOST:PORT?tls=true|false&scope=single-node"
         , "  Cluster target:   redis+cluster://HOST:PORT?tls=true|false&scope=all-primaries"
         , "  In a terminal, --flush prompts for the exact displayed target."
         , "  Without a terminal, --confirm-flush must exactly match that target."
         , "  With --processes > 1, only the parent confirms and flushes once before spawning children."
         , ""
         , "Examples:"
         ]
      ++ map ("  " ++) exampleCommands

renderReadmeCliReference :: String
renderReadmeCliReference =
  unlines $
    [ "#### Public modes"
    , ""
    , "| Mode | Purpose | Notes |"
    , "| --- | --- | --- |"
    ]
      ++ map renderModeRow modeDocs
      ++ [ ""
         , "#### Public options"
         , ""
         , "| Option | Applies to | Details |"
         , "| --- | --- | --- |"
         ]
      ++ map renderOptionRow optionDocs
      ++ [ ""
         , "#### Environment variables"
         , ""
         , "| Name | Details |"
         , "| --- | --- |"
         ]
      ++ map renderEnvironmentRow environmentDocs
      ++ [ ""
         , "#### Flush confirmation"
         , ""
         , "- `--flush` is intent only. The client never sends `FLUSHALL` without an exact confirmation target."
         , "- Standalone target: `redis://HOST:PORT?tls=true|false&scope=single-node`"
         , "- Cluster target: `redis+cluster://HOST:PORT?tls=true|false&scope=all-primaries`"
         , "- In a terminal, the client prompts for the exact displayed target. In non-interactive automation, pass that exact value with `--confirm-flush`."
         , "- With `--processes N` for `N > 1`, only the parent process confirms and flushes once before spawning children."
         , ""
         , "#### Representative examples"
         , ""
         , "```sh"
         ]
      ++ exampleCommands
      ++ ["```"]

modeDocs :: [ModeDoc]
modeDocs =
  [ ModeDoc
      { modeName = "cli"
      , modePurpose = "Interactive Redis REPL."
      , modeNotes = "Standalone by default; add `--cluster` for cluster seed-node routing."
      }
  , ModeDoc
      { modeName = "fill"
      , modePurpose = "Load random data for testing."
      , modeNotes = "Supports destructive flushes only with exact confirmation."
      }
  , ModeDoc
      { modeName = "tunn"
      , modePurpose = "Start the proxy/tunnel entrypoint."
      , modeNotes = "Standalone mode requires `--tls`; cluster mode supports `smart` and `pinned`."
      }
  , ModeDoc
      { modeName = "bench"
      , modePurpose = "Measure cluster throughput."
      , modeNotes = "Requires `--cluster` and emits a JSON summary to stdout."
      }
  ]

optionDocs :: [OptionDoc]
optionDocs =
  [ OptionDoc
      { optionFlags = "`--help`"
      , optionApplies = "all"
      , optionDetails = "Print this help text and exit with status 0."
      }
  , OptionDoc
      { optionFlags = "`-h`, `--host HOST`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "Redis host or cluster seed node. Required for every mode except `--help`."
      }
  , OptionDoc
      { optionFlags = "`-p`, `--port PORT`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "Connection port. Defaults to 6379 for plaintext and 6380 for TLS."
      }
  , OptionDoc
      { optionFlags = "`-u`, `--username USERNAME`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "ACL username used with environment-provided credentials. Default: `default`."
      }
  , OptionDoc
      { optionFlags = "`-t`, `--tls`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "Use TLS for the upstream Redis connection."
      }
  , OptionDoc
      { optionFlags = "`--allow-insecure-plaintext-auth`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "Allow environment-provided credentials over plaintext and emit a warning naming the target host."
      }
  , OptionDoc
      { optionFlags = "`-c`, `--cluster`"
      , optionApplies = "`cli`, `fill`, `tunn`, `bench`"
      , optionDetails = "Enable Redis Cluster behavior. Required for `bench`; optional for the other modes."
      }
  , OptionDoc
      { optionFlags = "`--verbose-pinned-proxy-traffic`"
      , optionApplies = "`tunn`"
      , optionDetails = "Enable opt-in pinned-proxy request/response payload previews for debugging. Default: off."
      }
  , OptionDoc
      { optionFlags = "`-d`, `--data GBs`"
      , optionApplies = "`fill`"
      , optionDetails = "Random data size in GiB. Required unless `--flush` is the only requested action."
      }
  , OptionDoc
      { optionFlags = "`-f`, `--flush`"
      , optionApplies = "`fill`"
      , optionDetails = "Request `FLUSHALL` before filling, or perform a flush-only run when `--data` is omitted. Requires exact confirmation."
      }
  , OptionDoc
      { optionFlags = "`--confirm-flush TARGET`"
      , optionApplies = "`fill`"
      , optionDetails = "Exact non-interactive acknowledgement for `--flush`. Required whenever stdin is not a terminal."
      }
  , OptionDoc
      { optionFlags = "`-s`, `--serial`"
      , optionApplies = "`fill`"
      , optionDetails = "Disable concurrent fill workers and run the fill loop serially."
      }
  , OptionDoc
      { optionFlags = "`-n`, `--connections NUM`"
      , optionApplies = "`fill`, `bench`"
      , optionDetails = "Parallel worker count. Default: " ++ show defaultConnections ++ ". In `fill`, this is standalone connections or cluster threads per node; in `bench`, this is benchmark worker threads."
      }
  , OptionDoc
      { optionFlags = "`--key-size BYTES`"
      , optionApplies = "`fill`, `bench`"
      , optionDetails = "Key size. Default: " ++ show (keySize defaultRunState) ++ " bytes. Range: 1-65536."
      }
  , OptionDoc
      { optionFlags = "`--value-size BYTES`"
      , optionApplies = "`fill`, `bench`"
      , optionDetails = "Value size. Default: " ++ show (valueSize defaultRunState) ++ " bytes. Range: 1-524288."
      }
  , OptionDoc
      { optionFlags = "`--pipeline COUNT`"
      , optionApplies = "`fill`"
      , optionDetails = "Commands per pipeline batch. Default: " ++ show (pipelineBatchSize defaultRunState) ++ ". Minimum: 1."
      }
  , OptionDoc
      { optionFlags = "`-P`, `--processes NUM`"
      , optionApplies = "`fill`"
      , optionDetails = "Parallel child processes for `fill`. Default: " ++ show defaultProcesses ++ ". Only the parent process confirms and performs `--flush`."
      }
  , OptionDoc
      { optionFlags = "`--tunnel-mode MODE`"
      , optionApplies = "`tunn`"
      , optionDetails = "Cluster tunnel strategy. Values: `smart` or `pinned`. Default: `" ++ tunnelMode defaultRunState ++ "`."
      }
  , OptionDoc
      { optionFlags = "`--operation OP`"
      , optionApplies = "`bench`"
      , optionDetails = "Benchmark workload. Values: `set`, `get`, or `mixed`. Default: `" ++ benchOperation defaultRunState ++ "`."
      }
  , OptionDoc
      { optionFlags = "`--duration SECS`"
      , optionApplies = "`bench`"
      , optionDetails = "Benchmark duration in seconds. Default: " ++ show (benchDuration defaultRunState) ++ ". Minimum: 1."
      }
  , OptionDoc
      { optionFlags = "`--mux-count NUM`"
      , optionApplies = "`bench`"
      , optionDetails = "Multiplexers per cluster node during `bench`. Default: " ++ show (muxCount defaultRunState) ++ ". Minimum: 1."
      }
  ]

environmentDocs :: [EnvironmentDoc]
environmentDocs =
  [ EnvironmentDoc
      { environmentName = "`" ++ passwordFileEnvironmentVariable ++ "`"
      , environmentDetails = "Path to a Redis credential file. Highest precedence; strips one trailing newline."
      }
  , EnvironmentDoc
      { environmentName = "`" ++ passwordEnvironmentVariable ++ "`"
      , environmentDetails = "Redis credential value used only when `" ++ passwordFileEnvironmentVariable ++ "` is unset."
      }
  , EnvironmentDoc
      { environmentName = "`REDIS_CLIENT_TLS_INSECURE`"
      , environmentDetails = "Set to exactly `1` to disable TLS certificate verification. Unset, empty, `0`, and `false` keep verification enabled; every other value is rejected."
      }
  ]

exampleCommands :: [String]
exampleCommands =
  [ "redis-client --help"
  , "redis-client cli -h localhost"
  , "redis-client cli -h localhost -c"
  , "redis-client fill -h localhost -d 5 --pipeline 4096 --key-size 128 --value-size 1024"
  , "redis-client fill -h localhost -f --confirm-flush 'redis://localhost:6379?tls=false&scope=single-node'"
  , "redis-client fill -h redis1.local -c -d 10 -n 4 -P 2"
  , "redis-client tunn -h redis1.local -t -c --tunnel-mode smart"
  , "redis-client tunn -h redis1.local -c --tunnel-mode pinned --verbose-pinned-proxy-traffic"
  , "redis-client bench -h redis1.local -c --operation mixed --duration 15 --connections 32 --mux-count 2"
  , "REDIS_CLIENT_PASSWORD_FILE=/secure/redis.pass redis-client cli -h cache.local -t"
  ]

defaultConnections :: Int
defaultConnections = fromMaybe 2 (numConnections defaultRunState)

defaultProcesses :: Int
defaultProcesses = 1

renderModeLine :: ModeDoc -> String
renderModeLine mode =
  "  " ++ padRight 6 (modeName mode) ++ "  "
    ++ stripMarkdown (modePurpose mode)
    ++ " "
    ++ stripMarkdown (modeNotes mode)

renderModeRow :: ModeDoc -> String
renderModeRow mode =
  "| `" ++ modeName mode ++ "` | " ++ modePurpose mode ++ " | " ++ modeNotes mode ++ " |"

renderOptionRow :: OptionDoc -> String
renderOptionRow option =
  "| " ++ optionFlags option ++ " | " ++ optionApplies option ++ " | " ++ optionDetails option ++ " |"

renderEnvironmentRow :: EnvironmentDoc -> String
renderEnvironmentRow env =
  "| " ++ environmentName env ++ " | " ++ environmentDetails env ++ " |"

renderAlignedTable :: [(String, Int)] -> [[String]] -> [String]
renderAlignedTable columns rows =
  let header = intercalate "  " (zipWith renderHeader columns [0 ..])
      divider = intercalate "  " (map renderDivider columns)
      renderedRows = map renderRow rows
  in header : divider : renderedRows
  where
    renderHeader (title, width) idx =
      let value = if idx == length columns - 1 || width == 0 then title else padRight width title
      in value
    renderDivider (_, width)
      | width == 0 = "-------"
      | otherwise = replicate width '-'
    renderRow values =
      intercalate "  " (zipWith3 renderCell values columns [0 ..])
    renderCell value (_, width) idx
      | idx == length columns - 1 || width == 0 = stripMarkdown value
      | otherwise = padRight width (stripMarkdown value)

padRight :: Int -> String -> String
padRight width value = value ++ replicate (max 0 (width - length value)) ' '

stripMarkdown :: String -> String
stripMarkdown = filter (/= '`')
