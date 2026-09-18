{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           ClusterFiller                         (fillClusterWithData,
                                                        withClusterFillClient)
import           Database.Redis.Client                 (Client (receive, send),
                                                        TLSClient (..), serve)
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterCommandClient,
                                                        closeClusterClient,
                                                        runClusterCommandClient)

import           ClusterSetup                          (createClusterClientFromState,
                                                        createPlaintextConnector,
                                                        createTLSConnector,
                                                        flushAllClusterNodes)
import           ClusterTunnel                         (PinnedProxyLogMode (..),
                                                        servePinnedProxyWith,
                                                        serveSmartProxy)
import           Control.Exception                     (bracket, mask, throwIO)

import           AppConfig                             (RunState (..),
                                                        defaultRunState,
                                                        resolveRunStateCredentials,
                                                        runCommandsAgainstPlaintextHost,
                                                        runCommandsAgainstTLSHost,
                                                        warnIfInsecurePlaintextAuthentication)
import           ClusterCli                            (routeAndExecuteCommand)
import           CommandHelp                           (helpFlag, publicModes,
                                                        renderCommandHelp)
import           Control.Concurrent.STM                (readTVarIO)
import           Control.Monad                         (unless, void, when)
import           Control.Monad.IO.Class
import qualified Control.Monad.State                   as State
import           CredentialConfig                      (rejectCredentialArguments)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Builder               as Builder
import qualified Data.ByteString.Char8                 as BS8
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe, isNothing)
import           Data.Time.Clock                       (diffUTCTime,
                                                        getCurrentTime)
import           Data.Word                             (Word64, Word8)
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeRole (..),
                                                        calculateSlot,
                                                        findNodeAddressForSlot)
import           Database.Redis.Command                (ClientState (ClientState),
                                                        RedisCommandClient,
                                                        RedisCommands (..),
                                                        encodeGetBuilder,
                                                        encodeSetBuilder,
                                                        parseWith)
import           Database.Redis.Connector              (Connector)
import           Database.Redis.Internal.MultiplexPool (MultiplexPool,
                                                        closeMultiplexPool,
                                                        createMultiplexPool,
                                                        submitToNode,
                                                        submitToNodeAsync,
                                                        waitSlotResult)
import           Database.Redis.Resp                   (Encodable (encode),
                                                        RespData (RespArray, RespBulkString))
import           Filler                                (fillCacheWithData,
                                                        fillCacheWithDataMB,
                                                        initRandomNoise)
import           FillLimits                            (FillConcurrencyPlan (..),
                                                        clusterFillConcurrencyPlan,
                                                        effectiveFillConnections,
                                                        fillConcurrencyPlan,
                                                        formatMemoryEstimate)
import           FillProcess                           (buildChildArgs)
import           FlushConfirmation                     (canonicalFlushTarget,
                                                        confirmFlush)
import           Numeric                               (showHex)
import           ProcessLifecycle                      (waitForChildProcesses)
import           StructuredConcurrency                 (runConcurrentlyFailFast,
                                                        withSubmittedSlots)
import           System.Console.GetOpt                 (ArgDescr (..),
                                                        ArgOrder (..),
                                                        OptDescr (Option),
                                                        getOpt)
import           System.Console.Readline               (addHistory, readline)
import           System.Environment                    (getArgs,
                                                        getExecutablePath)
import           System.Exit                           (exitFailure,
                                                        exitSuccess)
import           System.IO                             (hIsTerminalDevice,
                                                        hPutStrLn, isEOF,
                                                        stderr, stdin)
import           System.Process                        (ProcessHandle,
                                                        createProcess, proc)
import           System.Random                         (randomIO)
import           Text.Printf                           (printf)
import           Text.Read                             (readMaybe)

options :: [OptDescr (RunState -> IO RunState)]
options =
  [ Option ['h'] ["host"] (ReqArg (\arg opt -> return $ opt {host = arg}) "HOST") "Host to connect to",
    Option ['p'] ["port"] (ReqArg (setInt "Port" (\value opt -> opt {port = Just value})) "PORT") "Port to connect to. Will default to 6379 for plaintext and 6380 for TLS",
    Option ['u'] ["username"] (ReqArg (\arg opt -> return $ opt {username = arg}) "USERNAME") "Username to authenticate with (default: 'default')",
    Option ['t'] ["tls"] (NoArg (\opt -> return $ opt {useTLS = True})) "Use TLS",
    Option [] ["allow-insecure-plaintext-auth"] (NoArg (\opt -> return $ opt {allowInsecurePlaintextAuth = True})) "Allow credentials over plaintext and emit a warning",
    Option [] ["verbose-pinned-proxy-traffic"] (NoArg (\opt -> return $ opt {pinnedProxyVerboseTraffic = True})) "Emit per-request pinned-proxy payload previews (debug only)",
    Option ['d'] ["data"] (ReqArg (setInt "Data amount" (\value opt -> opt {dataGBs = value})) "GBs") "Random data amount to send in GB",
    Option ['f'] ["flush"] (NoArg (\opt -> return $ opt {flush = True})) "Request a destructive FLUSHALL; requires confirmation",
    Option [] ["confirm-flush"] (ReqArg (\arg opt -> return $ opt {flushConfirmation = Just arg}) "TARGET") "Non-interactive acknowledgement of the exact displayed flush target",
    Option ['s'] ["serial"] (NoArg (\opt -> return $ opt {serial = True})) "Run in serial mode (no concurrency)",
    Option ['n'] ["connections"] (ReqArg (setInt "Connection count" (\value opt -> opt {numConnections = Just value})) "NUM") "Number of parallel connections per process (default: 2; maximum: 16 without --allow-high-scale-fill)",
    Option ['c'] ["cluster"] (NoArg (\opt -> return $ opt {useCluster = True})) "Use Redis Cluster mode",
    Option [] ["tunnel-mode"] (ReqArg (\arg opt -> return $ opt {tunnelMode = arg}) "MODE") "Tunnel mode: 'smart' (default) or 'pinned'",
    Option [] ["key-size"] (ReqArg (\arg opt -> do
        size <- readInt "Key size" arg
        if size < 1
          then ioError (userError "Key size must be at least 1 byte")
          else if size > 65536
            then ioError (userError "Key size must not exceed 65536 bytes")
            else return $ opt {keySize = size}) "BYTES") "Size of each key in bytes (default: 512, range: 1-65536)",
    Option [] ["value-size"] (ReqArg (\arg opt -> do
        size <- readInt "Value size" arg
        if size < 1
          then ioError (userError "Value size must be at least 1 byte")
          else if size > 524288
            then ioError (userError "Value size must not exceed 524288 bytes")
            else return $ opt {valueSize = size}) "BYTES") "Size of each value in bytes (default: 512, range: 1-524288)",
    Option [] ["pipeline"] (ReqArg (\arg opt -> do
        size <- readInt "Pipeline batch size" arg
        if size < 1
          then ioError (userError "Pipeline batch size must be at least 1")
          else return $ opt {pipelineBatchSize = size}) "COUNT") "Number of commands per pipeline batch (default: 8192)",
    Option ['P'] ["processes"] (ReqArg (setInt "Process count" (\value opt -> opt {numProcesses = Just value})) "NUM") "Number of parallel processes to spawn (default: 1; maximum: 8 without --allow-high-scale-fill)",
    Option [] ["process-index"] (ReqArg (setInt "Process index" (\value opt -> opt {processIndex = Just value})) "INDEX") "Internal: Process index (used when spawning child processes)",
    Option [] ["allow-high-scale-fill"] (NoArg (\opt -> return $ opt {allowHighScaleFill = True})) "Allow fill plans above the 8-process, 16-connection, 32-worker, and 2 GiB estimated-memory safety limits",
    Option [] ["operation"] (ReqArg (\arg opt -> do
        if arg `elem` ["set", "get", "mixed"]
          then return $ opt {benchOperation = arg}
          else ioError (userError "Operation must be 'set', 'get', or 'mixed'")) "OP") "Benchmark operation: set, get, or mixed (default: set)",
    Option [] ["duration"] (ReqArg (\arg opt -> do
        dur <- readInt "Duration" arg
        if dur < 1
          then ioError (userError "Duration must be at least 1 second")
          else return $ opt {benchDuration = dur}) "SECS") "Benchmark duration in seconds (default: 30)",
    Option [] ["mux-count"] (ReqArg (\arg opt -> do
        cnt <- readInt "Mux count" arg
        if cnt < 1
          then ioError (userError "Mux count must be at least 1")
          else return $ opt {muxCount = cnt}) "NUM") "Number of multiplexers per cluster node (default: 1)"
  ]

readInt :: String -> String -> IO Int
readInt label value =
  case readMaybe value of
    Nothing  -> ioError $ userError $ label ++ " must be a valid integer"
    Just int -> pure int

setInt :: String -> (Int -> RunState -> RunState) -> String -> RunState -> IO RunState
setInt label update value state = do
  int <- readInt label value
  pure $ update int state

handleArgs :: [String] -> IO (RunState, [String])
handleArgs args = do
  case getOpt Permute options args of
    (o, n, [])   -> (,n) <$> foldl (>>=) (return defaultRunState) o
    (_, _, errs) -> ioError (userError (concat errs ++ renderCommandHelp))

main :: IO ()
main = do
  args' <- getArgs
  case rejectCredentialArguments args' of
    Left message -> hPutStrLn stderr message >> exitFailure
    Right ()     -> pure ()
  when (helpFlag `elem` args') $ do
    putStr renderCommandHelp
    exitSuccess
  case args' of
    [] -> putStr renderCommandHelp >> exitFailure
    (mode : args) -> do
      (parsedState, _) <- handleArgs args
      state <- resolveRunStateCredentials parsedState
      unless (mode `elem` publicModes) $ do
        printf "Invalid mode '%s' specified\nValid modes are %s\n" mode (quoteModes publicModes)
        putStr renderCommandHelp
        exitFailure
      when (null (host state)) $ do
        putStrLn "No host specified\n"
        putStr renderCommandHelp
        exitFailure
      warnIfInsecurePlaintextAuthentication state
      when (mode == "tunn") $ tunn state
      when (mode == "cli") $ cli state
      when (mode == "fill") $ fill state
      when (mode == "bench") $ bench state

quoteModes :: [String] -> String
quoteModes []             = ""
quoteModes [mode]         = "'" ++ mode ++ "'"
quoteModes [modeA, modeB] = "'" ++ modeA ++ "' and '" ++ modeB ++ "'"
quoteModes (mode:rest)    = "'" ++ mode ++ "', " ++ quoteModes rest


tunn :: RunState -> IO ()
tunn state = do
  if useCluster state
    then tunnCluster state
    else tunnStandalone state
  exitSuccess

tunnStandalone :: RunState -> IO ()
tunnStandalone state = do
  putStrLn "Starting tunnel mode (standalone)"
  if useTLS state
    then runCommandsAgainstTLSHost state $ do
      ClientState !client _ <- State.get
      serve (TLSTunnel client)
    else do
      putStrLn "Tunnel mode is only supported with TLS enabled\n"
      exitFailure

tunnCluster :: RunState -> IO ()
tunnCluster state = do
  putStrLn "Starting tunnel mode (cluster)"
  putStrLn $ "Tunnel mode: " ++ tunnelMode state

  -- Create cluster client
  if useTLS state
    then do
      let connector = createTLSConnector state
      clusterClient <- createClusterClientFromState state connector
      case tunnelMode state of
        "smart" -> do
          putStrLn "Smart proxy mode: Commands will be routed to appropriate cluster nodes"
          serveSmartProxy clusterClient
        "pinned" -> do
          putStrLn "Pinned mode: Creating one listener per cluster node"
          servePinnedProxyWith (pinnedProxyLogMode state) clusterClient
        _ -> do
          printf "Invalid tunnel mode '%s'. Valid modes: smart, pinned\n" (tunnelMode state)
          exitFailure
    else do
      let connector = createPlaintextConnector state
      clusterClient <- createClusterClientFromState state connector
      case tunnelMode state of
        "smart" -> do
          putStrLn "Smart proxy mode: Commands will be routed to appropriate cluster nodes"
          putStrLn "Note: TLS is recommended for production use"
          serveSmartProxy clusterClient
        "pinned" -> do
          putStrLn "Pinned mode: Creating one listener per cluster node"
          putStrLn "Note: TLS is recommended for production use"
          servePinnedProxyWith (pinnedProxyLogMode state) clusterClient
        _ -> do
          printf "Invalid tunnel mode '%s'. Valid modes: smart, pinned\n" (tunnelMode state)
          exitFailure

pinnedProxyLogMode :: RunState -> PinnedProxyLogMode
pinnedProxyLogMode state
  | pinnedProxyVerboseTraffic state = PinnedProxyVerboseTraffic
  | otherwise = PinnedProxyLifecycleOnly

fill :: RunState -> IO ()
fill state = do
  (masterCount, plan) <- preflightFillPlan state
  when (dataGBs state > 0) $
    maybe (reportFillPlan "Fill capacity" plan)
      (\count -> reportClusterFillPlan count plan)
      masterCount
  when (flush state) $ do
    let target = canonicalFlushTarget (host state) (port state) (useTLS state) (useCluster state)
    confirmation <- confirmFlush (flushConfirmation state) target
    case confirmation of
      Left message -> hPutStrLn stderr message >> exitFailure
      Right ()     -> pure ()

  -- If no data specified and no flush flag, show error
  when (dataGBs state <= 0 && not (flush state)) $ do
    putStrLn "No data specified or data is 0GB or fewer\n"
    putStr renderCommandHelp
    exitFailure

  -- If only flush requested (no data), just flush and exit
  when (dataGBs state <= 0 && flush state) $ do
    flushCache state
    putStrLn "Flush complete"
    exitSuccess

  -- Check if we should spawn multiple processes
  case (numProcesses state, processIndex state) of
    (Just nprocs, Nothing) | nprocs > 1 -> do
      -- Parent process: spawn children
      spawnFillProcesses state nprocs
      exitSuccess
    _ -> do
      -- Single process or child process: do the work
      if useCluster state
        then fillCluster state
        else fillStandalone state

      -- Exit with success
      exitSuccess

preflightFillPlan :: RunState -> IO (Maybe Int, FillConcurrencyPlan)
preflightFillPlan state
  | useCluster state && dataGBs state > 0 = do
    let discover connector =
          withClusterFillClient (createClusterClientFromState state connector) $ \clusterClient -> do
            topology <- readTVarIO $ clusterTopology clusterClient
            let primaryCount = length
                  [ node
                  | node <- Map.elems (topologyNodes topology)
                  , nodeRole node == Master
                  ]
            case clusterFillConcurrencyPlan primaryCount state of
              Left message -> hPutStrLn stderr message >> exitFailure
              Right plan   -> pure (Just primaryCount, plan)
    if useTLS state
      then discover (createTLSConnector state)
      else discover (createPlaintextConnector state)
  | otherwise =
    case fillConcurrencyPlan state of
      Left message -> hPutStrLn stderr message >> exitFailure
      Right plan   -> pure (Nothing, plan)

-- | Spawn multiple fill processes in parallel
spawnFillProcesses :: RunState -> Int -> IO ()
spawnFillProcesses state nprocs = do
  exePath <- getExecutablePath

  -- Flush once before spawning processes (if requested)
  when (flush state) $ do
    printf "Flushing cache before spawning %d processes\n" nprocs
    flushCache state

  -- Calculate data per process
  let totalGB = dataGBs state
      baseGB = totalGB `div` nprocs
      remainder = totalGB `mod` nprocs

  printf "Spawning %d processes to fill %dGB total (key size: %d bytes, value size: %d bytes)\n"
         nprocs totalGB (keySize state) (valueSize state)

  -- Spawn child processes
  handles <- mapM (spawnChildProcess exePath state baseGB remainder) [0..nprocs-1]

  -- Wait for all children and propagate the first non-zero child status.
  waitForChildProcesses handles
  printf "All %d processes completed\n" nprocs

-- | Spawn a single child process with its portion of data
spawnChildProcess :: FilePath -> RunState -> Int -> Int -> Int -> IO ProcessHandle
spawnChildProcess exePath state baseGB remainder idx = do
  let gbForThisProcess = if idx < remainder then baseGB + 1 else baseGB
      args = buildChildArgs state idx gbForThisProcess

  printf "  Process %d: %dGB\n" (idx + 1) gbForThisProcess

  (_, _, _, ph) <- createProcess (proc exePath args)
  return ph

flushCache :: RunState -> IO ()
flushCache state
  | useCluster state = do
      printf "Flushing all primary cluster nodes (seed node: '%s')\n" (host state)
      if useTLS state
        then do
          let connector = createTLSConnector state
          bracket (createClusterClientFromState state connector) closeClusterClient $ \clusterClient ->
            flushAllClusterNodes clusterClient connector
        else do
          let connector = createPlaintextConnector state
          bracket (createClusterClientFromState state connector) closeClusterClient $ \clusterClient ->
            flushAllClusterNodes clusterClient connector
  | otherwise = do
      printf "Flushing cache '%s'\n" (host state)
      if useTLS state
        then runCommandsAgainstTLSHost state (do { (_ :: RespData) <- flushAll; pure () })
        else runCommandsAgainstPlaintextHost state (do { (_ :: RespData) <- flushAll; pure () })

fillStandalone :: RunState -> IO ()
fillStandalone state = do
  -- Only the parent process performs a requested flush.
  when (flush state && isNothing (processIndex state)) $ do
    flushCache state
  when (dataGBs state > 0) $ do
    initRandomNoise -- Ensure noise buffer is initialized once and shared
    baseSeed <- randomIO :: IO Word64
    if serial state
      then do
        let seedOffset = fromMaybe 0 (processIndex state)
        printf "Filling %dGB (serial mode)\n" (dataGBs state)
        if useTLS state
          then runCommandsAgainstTLSHost state $ fillCacheWithData baseSeed seedOffset (dataGBs state) (pipelineBatchSize state) (keySize state) (valueSize state)
          else runCommandsAgainstPlaintextHost state $ fillCacheWithData baseSeed seedOffset (dataGBs state) (pipelineBatchSize state) (keySize state) (valueSize state)
      else do
        let nConns = effectiveFillConnections state
            totalMB = dataGBs state * 1024  -- Work in MB for finer granularity
            baseMB = totalMB `div` nConns
            remainder = totalMB `mod` nConns
            -- Each connection gets (baseMB + 1) or baseMB MB
            -- Jobs: (connectionIdx, mbForThisConnection)
            jobs = [(i, if i < remainder then baseMB + 1 else baseMB) | i <- [0..nConns - 1], baseMB > 0 || i < remainder]
        printf "Filling %dGB with %d parallel connections\n" (dataGBs state) (length jobs)
        runConcurrentlyFailFast
          [ if useTLS state
              then runCommandsAgainstTLSHost state $ fillCacheWithDataMB baseSeed idx mb (pipelineBatchSize state) (keySize state) (valueSize state)
              else runCommandsAgainstPlaintextHost state $ fillCacheWithDataMB baseSeed idx mb (pipelineBatchSize state) (keySize state) (valueSize state)
          | (idx, mb) <- jobs
          ]


fillCluster :: RunState -> IO ()
fillCluster state = do
  when (flush state) $ do
    flushCache state

  when (dataGBs state > 0) $ do
    -- Get base seed for randomness
    baseSeed <- randomIO :: IO Word64

    -- Determine number of threads per node
    let threadsPerNode = effectiveFillConnections state

    printf "Filling %dGB across cluster with %d threads/node\n"
           (dataGBs state) threadsPerNode

    -- Create cluster client and fill data
    if useTLS state
      then do
        let connector = createTLSConnector state
        withClusterFillClient (createClusterClientFromState state connector) $ \clusterClient ->
          runClusterFill state clusterClient connector threadsPerNode baseSeed
      else do
        let connector = createPlaintextConnector state
        withClusterFillClient (createClusterClientFromState state connector) $ \clusterClient ->
          runClusterFill state clusterClient connector threadsPerNode baseSeed

runClusterFill :: Client client => RunState -> ClusterClient client -> Connector client -> Int -> Word64 -> IO ()
runClusterFill state clusterClient connector threadsPerNode baseSeed = do
  topology <- readTVarIO $ clusterTopology clusterClient
  let masterCount = length [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  plan <-
    case clusterFillConcurrencyPlan masterCount state of
      Left message -> hPutStrLn stderr message >> exitFailure
      Right value  -> pure value
  printf
    "Cluster fill capacity: %d processes x %d primaries x %d connections = %d workers; estimated peak client memory %s\n"
    (plannedProcesses plan)
    masterCount
    (plannedConnections plan)
    (plannedWorkerCount plan)
    (formatMemoryEstimate $ estimatedMemoryBytes plan)
  fillClusterWithData clusterClient connector
    (dataGBs state) threadsPerNode baseSeed (keySize state) (valueSize state) (pipelineBatchSize state)

reportFillPlan :: String -> FillConcurrencyPlan -> IO ()
reportFillPlan label plan =
  printf "%s: %d processes x %d connections = %d workers; estimated peak client memory %s\n"
    label
    (plannedProcesses plan)
    (plannedConnections plan)
    (plannedWorkerCount plan)
    (formatMemoryEstimate $ estimatedMemoryBytes plan)

reportClusterFillPlan :: Int -> FillConcurrencyPlan -> IO ()
reportClusterFillPlan masterCount plan =
  printf "%d-primary cluster fill capacity: %d processes x %d primaries x %d connections = %d workers; estimated peak client memory %s\n"
    masterCount
    (plannedProcesses plan)
    masterCount
    (plannedConnections plan)
    (plannedWorkerCount plan)
    (formatMemoryEstimate $ estimatedMemoryBytes plan)

cli :: RunState -> IO ()
cli state = do
  if useCluster state
    then cliCluster state
    else cliStandalone state
  exitSuccess

cliStandalone :: RunState -> IO ()
cliStandalone state = do
  putStrLn "Starting CLI mode (standalone)"
  isTTY <- hIsTerminalDevice stdin
  if useTLS state
    then runCommandsAgainstTLSHost state (repl isTTY)
    else runCommandsAgainstPlaintextHost state (repl isTTY)

cliCluster :: RunState -> IO ()
cliCluster state = do
  putStrLn "Starting CLI mode (cluster)"
  isTTY <- hIsTerminalDevice stdin
  if useTLS state
    then do
      clusterClient <- createClusterClientFromState state (createTLSConnector state)
      putStrLn $ "Connected to cluster seed node: " ++ host state
      result <- runClusterCommandClient clusterClient (replCluster isTTY)
      closeClusterClient clusterClient
      either throwIO pure result
    else do
      clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
      putStrLn $ "Connected to cluster seed node: " ++ host state
      result <- runClusterCommandClient clusterClient (replCluster isTTY)
      closeClusterClient clusterClient
      either throwIO pure result

repl :: (Client client) => Bool -> RedisCommandClient client ()
repl isTTY = do
  ClientState !client _ <- State.get
  loop client
  where
    loop !client = do
      command <- liftIO $ readCommand isTTY
      case command of
        Nothing -> return ()
        Just cmd -> do
          when isTTY $ liftIO $ addHistory cmd
          unless (cmd == "exit") $ do
            (send client . Builder.toLazyByteString . encode . RespArray . map (RespBulkString . BS8.pack)) . words $ cmd
            response <- parseWith (receive client)
            liftIO $ print $ encodeBytesForCLI $ BS8.pack (show response)
            loop client

-- | REPL for cluster mode - uses ClusterCommandClient
replCluster :: (Client client) => Bool -> ClusterCommandClient client ()
replCluster isTTY = loop
  where
    loop = do
      command <- liftIO $ readCommand isTTY
      case command of
        Nothing -> return ()
        Just cmd -> do
          when isTTY $ liftIO $ addHistory cmd
          unless (cmd == "exit") $ do
            let parts = words cmd
            case parts of
              [] -> return ()
              (cm:args) -> do
                result <- routeAndExecuteCommand (map BS8.pack (cm:args))
                case result of
                  Left err       -> liftIO $ putStrLn $ "Error: " ++ err
                  Right response -> liftIO $ print $ encodeBytesForCLI $ BS8.pack (show response)
            loop

-- | Read a command from the user, handling TTY vs pipe input
readCommand :: Bool -> IO (Maybe String)
readCommand isTTY
  | isTTY = readline "> "
  | otherwise = do
      eof <- isEOF
      if eof
        then return Nothing
        else Just <$> getLine

isPrintableAscii :: Word8 -> Bool
isPrintableAscii b =
  (b >= 32 && b <= 126) || b == 10 -- space (32) to '~' (126), or newline (10)

encodeBytesForCLI :: BS.ByteString -> String
encodeBytesForCLI bs = concatMap encodeByte (BS.unpack bs)
  where
    encodeByte b
      | isPrintableAscii b = [toEnum (fromEnum b)]
      | otherwise          = "\\x" ++ padHex b
    padHex b = let h = showHex b "" in if length h == 1 then '0':h else h

-- | Generate a benchmark key of the specified size
benchKey :: Int -> Int -> BS.ByteString
benchKey size idx =
  let prefix = BS8.pack $ "bench:" ++ show idx ++ ":"
      padLen = max 0 (size - BS.length prefix)
  in BS.take size (prefix <> BS.replicate padLen 0x30) -- pad with '0'

-- | Generate a benchmark value of the specified size
benchValue :: Int -> Int -> BS.ByteString
benchValue size idx =
  let prefix = BS8.pack $ "val:" ++ show idx ++ ":"
      padLen = max 0 (size - BS.length prefix)
  in BS.take size (prefix <> BS.replicate padLen 0x58) -- pad with 'X'

-- | Benchmark mode: measures throughput of SET, GET, or mixed workloads
-- through the MultiplexPool/submitToNode code path.
bench :: RunState -> IO ()
bench state = do
  unless (useCluster state) $ do
    putStrLn "Bench mode requires -c (cluster) flag"
    exitFailure

  let op = benchOperation state
      duration = benchDuration state
      nConns = fromMaybe 16 (numConnections state)
      kSize = keySize state
      vSize = valueSize state
      muxCnt = muxCount state

  hPutStrLn stderr $ "Bench: operation=" ++ op ++ " duration=" ++ show duration
    ++ "s key-size=" ++ show kSize ++ " value-size=" ++ show vSize
    ++ " connections=" ++ show nConns ++ " mux-count=" ++ show muxCnt

  if useTLS state
    then benchWithConnector state (createTLSConnector state) op duration nConns kSize vSize
    else benchWithConnector state (createPlaintextConnector state) op duration nConns kSize vSize

-- | Run the benchmark with a specific connector type
benchWithConnector :: (Client client) => RunState -> Connector client -> String -> Int -> Int -> Int -> Int -> IO ()
benchWithConnector state connector op duration nConns kSize vSize =
  bracket (createClusterClientFromState state connector) closeClusterClient $ \clusterClient ->
    bracket (createMultiplexPool (clusterConnector clusterClient) (muxCount state)) closeMultiplexPool $ \muxPool -> do

      -- Pre-populate keys for GET and mixed workloads
      when (op `elem` ["get", "mixed"]) $ do
        hPutStrLn stderr "Pre-populating keys for GET workload..."
        let numKeys = 100000
        benchPrePopulate muxPool clusterClient numKeys kSize vSize
        hPutStrLn stderr $ "Pre-populated " ++ show numKeys ++ " keys"

      -- Run the benchmark
      opsCounter <- newIORef (0 :: Int)
      startTime <- getCurrentTime

      runConcurrentlyFailFast
        [ benchWorker muxPool clusterClient op tid kSize vSize duration opsCounter
        | tid <- [0 .. nConns - 1]
        ]

      endTime <- getCurrentTime

      totalOps <- readIORef opsCounter
      let elapsed = realToFrac (diffUTCTime endTime startTime) :: Double
          opsPerSec = fromIntegral totalOps / elapsed

      -- Output JSON to stdout
      putStrLn $ "{\"operation\":\"" ++ op
        ++ "\",\"ops_per_sec\":" ++ show (round opsPerSec :: Int)
        ++ ",\"duration_sec\":" ++ show (round elapsed :: Int)
        ++ ",\"total_ops\":" ++ show totalOps
        ++ "}"

      exitSuccess

-- | Pre-populate keys for GET workload
benchPrePopulate :: (Client client) => MultiplexPool client -> ClusterClient client -> Int -> Int -> Int -> IO ()
benchPrePopulate muxPool clusterClient numKeys kSize vSize = do
  topology <- readTVarIO (clusterTopology clusterClient)
  let masters = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  case masters of
    [] -> error "No master nodes found"
    _  -> mapM_ (\i -> do
      let key = benchKey kSize i
          val = benchValue vSize i
          cmd = encodeSetBuilder key val
          !slot = calculateSlot key
      case findNodeAddressForSlot topology slot of
        Just addr -> void $ submitToNode muxPool addr cmd
        Nothing   -> return ()
      ) [0 .. numKeys - 1]

-- | Worker thread that submits commands for the specified duration
-- Uses async pipelining: fires a batch of commands, then waits for all results.
benchWorker :: (Client client) => MultiplexPool client -> ClusterClient client -> String -> Int -> Int -> Int -> Int -> IORef Int -> IO ()
benchWorker muxPool clusterClient op tid kSize vSize duration opsCounter = mask $ \_ -> do
  topology <- readTVarIO (clusterTopology clusterClient)
  let masters = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
      batchSize = 64 -- fire 64 commands per batch before waiting
  startTime <- getCurrentTime
  go topology masters startTime (tid * 10000000) batchSize
  where
    go topology masters startTime !counter !batchSz = do
      now <- getCurrentTime
      let elapsed = realToFrac (diffUTCTime now startTime) :: Double
      when (elapsed < fromIntegral duration) $ do
        withSubmittedSlots (waitSlotResult muxPool) $ \submitted waitSubmitted -> do
          slots <- fireBatch topology counter batchSz [] submitted
          let completedCount = length slots
          mapM_ waitSubmitted slots
          atomicModifyIORef' opsCounter (\n -> (n + completedCount, ()))
        go topology masters startTime (counter + batchSz) batchSz

    fireBatch _ _ 0 acc _ = return (reverse acc)
    fireBatch topology !counter !remaining acc submitted = do
      let key = benchKey kSize counter
          val = benchValue vSize counter
          !slot = calculateSlot key
      case findNodeAddressForSlot topology slot of
        Just addr -> do
          let cmd = case op of
                "set" -> encodeSetBuilder key val
                "get" -> encodeGetBuilder key
                "mixed" ->
                  if counter `mod` 5 == 0
                    then encodeSetBuilder key val
                    else encodeGetBuilder key
                _ -> encodeSetBuilder key val
          s <- submitted (submitToNodeAsync muxPool addr cmd)
          fireBatch topology (counter + 1) (remaining - 1) (s : acc) submitted
        Nothing -> fireBatch topology (counter + 1) (remaining - 1) acc submitted
