{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (receive, send),
                                             TLSClient (..), serve)
import           ClusterCommandClient       (ClusterCommandClient,
                                             closeClusterClient,
                                             runClusterCommandClient)
import           ClusterFiller              (fillClusterWithData)
import qualified Data.ByteString.Lazy       as BL

import           ClusterSetup               (createClusterClientFromState,
                                             createPlaintextConnector,
                                             createTLSConnector,
                                             flushAllClusterNodes)
import           ClusterTunnel              (servePinnedProxy, serveSmartProxy)
import           Control.Concurrent         (forkIO, newEmptyMVar, putMVar,
                                             takeMVar)

import           ClusterCli                 (routeAndExecuteCommand)
import           Control.Monad              (unless, void, when)
import           Control.Monad.IO.Class
import qualified Control.Monad.State        as State
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Char8      as BSSC
import qualified Data.ByteString.Lazy.Char8 as BSC
import           Data.Maybe                 (fromMaybe, isNothing)
import           Data.Word                  (Word64, Word8)
import           Filler                     (fillCacheWithData,
                                             fillCacheWithDataMB,
                                             initRandomNoise)
import           Numeric                    (showHex)
import           AppConfig                  (RunState (..),
                                             defaultRunState,
                                             runCommandsAgainstPlaintextHost,
                                             runCommandsAgainstTLSHost)
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommandClient,
                                             RedisCommands (flushAll),
                                             parseWith)
import           Resp                       (Encodable (encode),
                                             RespData (RespArray, RespBulkString))
import           System.Console.GetOpt      (ArgDescr (..), ArgOrder (..),
                                             OptDescr (Option), getOpt,
                                             usageInfo)
import           System.Console.Readline    (addHistory, readline)
import           System.Environment         (getArgs, getExecutablePath)
import           System.Exit                (exitFailure, exitSuccess)
import           System.IO                  (hIsTerminalDevice, isEOF, stdin)
import           System.Process             (ProcessHandle, createProcess, proc,
                                             waitForProcess)
import           System.Random              (randomIO)
import           Text.Printf                (printf)

options :: [OptDescr (RunState -> IO RunState)]
options =
  [ Option ['h'] ["host"] (ReqArg (\arg opt -> return $ opt {host = arg}) "HOST") "Host to connect to",
    Option ['p'] ["port"] (ReqArg (\arg opt -> return $ opt {port = Just . read $ arg}) "PORT") "Port to connect to. Will default to 6379 for plaintext and 6380 for TLS",
    Option ['u'] ["username"] (ReqArg (\arg opt -> return $ opt {username = arg}) "USERNAME") "Username to authenticate with (default: 'default')",
    Option ['a'] ["password"] (ReqArg (\arg opt -> return $ opt {password = arg}) "PASSWORD") "Password to authenticate with",
    Option ['t'] ["tls"] (NoArg (\opt -> return $ opt {useTLS = True})) "Use TLS",
    Option ['d'] ["data"] (ReqArg (\arg opt -> return $ opt {dataGBs = read arg}) "GBs") "Random data amount to send in GB",
    Option ['f'] ["flush"] (NoArg (\opt -> return $ opt {flush = True})) "Flush the database",
    Option ['s'] ["serial"] (NoArg (\opt -> return $ opt {serial = True})) "Run in serial mode (no concurrency)",
    Option ['n'] ["connections"] (ReqArg (\arg opt -> return $ opt {numConnections = Just . read $ arg}) "NUM") "Number of parallel connections (default: 2)",
    Option ['c'] ["cluster"] (NoArg (\opt -> return $ opt {useCluster = True})) "Use Redis Cluster mode",
    Option [] ["tunnel-mode"] (ReqArg (\arg opt -> return $ opt {tunnelMode = arg}) "MODE") "Tunnel mode: 'smart' (default) or 'pinned'",
    Option [] ["key-size"] (ReqArg (\arg opt -> do
        let size = read arg :: Int
        if size < 1
          then ioError (userError "Key size must be at least 1 byte")
          else if size > 65536
            then ioError (userError "Key size must not exceed 65536 bytes")
            else return $ opt {keySize = size}) "BYTES") "Size of each key in bytes (default: 512, range: 1-65536)",
    Option [] ["value-size"] (ReqArg (\arg opt -> do
        let size = read arg :: Int
        if size < 1
          then ioError (userError "Value size must be at least 1 byte")
          else if size > 524288
            then ioError (userError "Value size must not exceed 524288 bytes")
            else return $ opt {valueSize = size}) "BYTES") "Size of each value in bytes (default: 512, range: 1-524288)",
    Option [] ["pipeline"] (ReqArg (\arg opt -> do
        let size = read arg :: Int
        if size < 1
          then ioError (userError "Pipeline batch size must be at least 1")
          else return $ opt {pipelineBatchSize = size}) "COUNT") "Number of commands per pipeline batch (default: 8192)",
    Option ['P'] ["processes"] (ReqArg (\arg opt -> return $ opt {numProcesses = Just . read $ arg}) "NUM") "Number of parallel processes to spawn (default: 1)",
    Option [] ["process-index"] (ReqArg (\arg opt -> return $ opt {processIndex = Just . read $ arg}) "INDEX") "Internal: Process index (used when spawning child processes)"
  ]

handleArgs :: [String] -> IO (RunState, [String])
handleArgs args = do
  case getOpt Permute options args of
    (o, n, []) -> (,n) <$> foldl (>>=) (return defaultRunState) o
    (_, _, errs) -> ioError (userError (concat errs ++ usageInfo "Usage: redis-client [mode] [OPTION...]" options))

main :: IO ()
main = do
  args' <- getArgs
  case args' of
    [] -> do
      putStrLn $ usageInfo "Usage: redis-client [mode] [OPTION...]" options
      putStrLn ""
      putStrLn "Modes:"
      putStrLn "  cli     Interactive Redis command-line interface"
      putStrLn "  fill    Fill Redis cache with random data for testing"
      putStrLn "  tunn    Start TLS tunnel proxy (requires -t flag)"
      putStrLn ""
      putStrLn "Cluster Mode:"
      putStrLn "  Use -c/--cluster flag to enable Redis Cluster support"
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  redis-client fill -h localhost -d 5                     # Fill 5GB standalone"
      putStrLn "  redis-client fill -h node1 -d 5 -c                      # Fill 5GB cluster"
      putStrLn "  redis-client cli -h localhost -c                        # CLI with cluster"
      putStrLn "  redis-client tunn -h node1 -t -c --tunnel-mode smart    # Smart cluster proxy"
      putStrLn "  redis-client fill ... --pipeline 4096                   # Use 4096 commands per pipeline"
      exitFailure
    (mode : args) -> do
      (state, _) <- handleArgs args
      unless (mode `elem` ["cli", "fill", "tunn"]) $ do
        printf "Invalid mode '%s' specified\nValid modes are 'cli', 'fill', and 'tunn'\n" mode
        putStrLn $ usageInfo "Usage: redis-client [mode] [OPTION...]" options
        exitFailure
      when (null (host state)) $ do
        putStrLn "No host specified\n"
        putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
        exitFailure
      when (mode == "tunn") $ tunn state
      when (mode == "cli") $ cli state
      when (mode == "fill") $ fill state


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
          servePinnedProxy clusterClient
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
          servePinnedProxy clusterClient
        _ -> do
          printf "Invalid tunnel mode '%s'. Valid modes: smart, pinned\n" (tunnelMode state)
          exitFailure

fill :: RunState -> IO ()
fill state = do
  -- If no data specified and no flush flag, show error
  when (dataGBs state <= 0 && not (flush state)) $ do
    putStrLn "No data specified or data is 0GB or fewer\n"
    putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
    exitFailure

  -- If only flush requested (no data), just flush and exit
  when (dataGBs state <= 0 && flush state) $ do
    if useCluster state
      then do
        printf "Flushing cluster cache (seed node: '%s')\n" (host state)
        if useTLS state
          then do
            clusterClient <- createClusterClientFromState state (createTLSConnector state)
            flushAllClusterNodes clusterClient (createTLSConnector state)
            closeClusterClient clusterClient
          else do
            clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
            flushAllClusterNodes clusterClient (createPlaintextConnector state)
            closeClusterClient clusterClient
      else do
        printf "Flushing cache '%s'\n" (host state)
        if useTLS state
          then runCommandsAgainstTLSHost state (void flushAll)
          else runCommandsAgainstPlaintextHost state (void flushAll)
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

-- | Spawn multiple fill processes in parallel
spawnFillProcesses :: RunState -> Int -> IO ()
spawnFillProcesses state nprocs = do
  exePath <- getExecutablePath

  -- Flush once before spawning processes (if requested)
  when (flush state && useCluster state) $ do
    printf "Flushing cluster cache before spawning %d processes\n" nprocs
    if useTLS state
      then do
        clusterClient <- createClusterClientFromState state (createTLSConnector state)
        flushAllClusterNodes clusterClient (createTLSConnector state)
        closeClusterClient clusterClient
      else do
        clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
        flushAllClusterNodes clusterClient (createPlaintextConnector state)
        closeClusterClient clusterClient

  when (flush state && not (useCluster state)) $ do
    printf "Flushing cache '%s' before spawning %d processes\n" (host state) nprocs
    if useTLS state
      then runCommandsAgainstTLSHost state (void flushAll)
      else runCommandsAgainstPlaintextHost state (void flushAll)

  -- Calculate data per process
  let totalGB = dataGBs state
      baseGB = totalGB `div` nprocs
      remainder = totalGB `mod` nprocs

  printf "Spawning %d processes to fill %dGB total (key size: %d bytes, value size: %d bytes)\n"
         nprocs totalGB (keySize state) (valueSize state)

  -- Spawn child processes
  handles <- mapM (spawnChildProcess exePath state baseGB remainder) [0..nprocs-1]

  -- Wait for all processes to complete
  mapM_ waitForProcess handles
  printf "All %d processes completed\n" nprocs

-- | Spawn a single child process with its portion of data
spawnChildProcess :: FilePath -> RunState -> Int -> Int -> Int -> IO ProcessHandle
spawnChildProcess exePath state baseGB remainder idx = do
  let gbForThisProcess = if idx < remainder then baseGB + 1 else baseGB
      args = buildChildArgs state idx gbForThisProcess

  printf "  Process %d: %dGB\n" (idx + 1) gbForThisProcess

  (_, _, _, ph) <- createProcess (proc exePath args)
  return ph

-- | Build command-line arguments for a child process
buildChildArgs :: RunState -> Int -> Int -> [String]
buildChildArgs state idx dataGB =
  [ "fill"
  , "-h", host state
  , "-d", show dataGB
  , "--process-index", show idx
  , "--key-size", show (keySize state)
  , "--value-size", show (valueSize state)
  , "--pipeline", show (pipelineBatchSize state)
  ]
  ++ (["-t" | useTLS state])
  ++ (["-c" | useCluster state])
  ++ (["-s" | serial state])
  ++ (case port state of
        Just p  -> ["-p", show p]
        Nothing -> [])
  ++ (if null (password state) then [] else ["-a", password state])
  ++ (if username state /= "default" then ["-u", username state] else [])
  ++ (case numConnections state of
        Just n  -> ["-n", show n]
        Nothing -> [])

fillStandalone :: RunState -> IO ()
fillStandalone state = do
  -- Only flush if we're not in multi-process mode (parent handles flush)
  when (flush state && isNothing (numProcesses state)) $ do
    printf "Flushing cache '%s'\n" (host state)
    if useTLS state
      then runCommandsAgainstTLSHost state (void flushAll)
      else runCommandsAgainstPlaintextHost state (void flushAll)
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
        -- Use numConnections (defaults to 8)
        let nConns = fromMaybe 8 (numConnections state)
            totalMB = dataGBs state * 1024  -- Work in MB for finer granularity
            baseMB = totalMB `div` nConns
            remainder = totalMB `mod` nConns
            -- Each connection gets (baseMB + 1) or baseMB MB
            -- Jobs: (connectionIdx, mbForThisConnection)
            jobs = [(i, if i < remainder then baseMB + 1 else baseMB) | i <- [0..nConns - 1], baseMB > 0 || i < remainder]
        printf "Filling %dGB with %d parallel connections\n" (dataGBs state) (length jobs)
        mvars <- mapM (\(idx, mb) -> do
            mv <- newEmptyMVar
            _ <- forkIO $ do
                 if useTLS state
                    then runCommandsAgainstTLSHost state $ fillCacheWithDataMB baseSeed idx mb (pipelineBatchSize state) (keySize state) (valueSize state)
                    else runCommandsAgainstPlaintextHost state $ fillCacheWithDataMB baseSeed idx mb (pipelineBatchSize state) (keySize state) (valueSize state)
                 putMVar mv ()
            return mv) jobs
        mapM_ takeMVar mvars


fillCluster :: RunState -> IO ()
fillCluster state = do
  when (flush state) $ do
    printf "Flushing cluster cache (seed node: '%s')\n" (host state)
    if useTLS state
      then do
        clusterClient <- createClusterClientFromState state (createTLSConnector state)
        flushAllClusterNodes clusterClient (createTLSConnector state)
        closeClusterClient clusterClient
      else do
        clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
        flushAllClusterNodes clusterClient (createPlaintextConnector state)
        closeClusterClient clusterClient

  when (dataGBs state > 0) $ do
    -- Get base seed for randomness
    baseSeed <- randomIO :: IO Word64

    -- Determine number of threads per node
    let threadsPerNode = fromMaybe 2 (numConnections state)

    printf "Filling %dGB across cluster with %d threads/node\n"
           (dataGBs state) threadsPerNode

    -- Create cluster client and fill data
    if useTLS state
      then do
        clusterClient <- createClusterClientFromState state (createTLSConnector state)
        fillClusterWithData clusterClient (createTLSConnector state)
                           (dataGBs state) threadsPerNode baseSeed (keySize state) (valueSize state) (pipelineBatchSize state)
        closeClusterClient clusterClient
      else do
        clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
        fillClusterWithData clusterClient (createPlaintextConnector state)
                           (dataGBs state) threadsPerNode baseSeed (keySize state) (valueSize state) (pipelineBatchSize state)
        closeClusterClient clusterClient

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
      runClusterCommandClient clusterClient (replCluster isTTY)
      closeClusterClient clusterClient
    else do
      clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
      putStrLn $ "Connected to cluster seed node: " ++ host state
      runClusterCommandClient clusterClient (replCluster isTTY)
      closeClusterClient clusterClient

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
            (send client . Builder.toLazyByteString . encode . RespArray . map (RespBulkString . BSC.pack)) . words $ cmd
            response <- parseWith (receive client)
            liftIO $ print $ encodeBytesForCLI $ BL.toStrict (BSC.pack (show response))
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
                result <- routeAndExecuteCommand (map BSSC.pack (cm:args))
                case result of
                  Left err       -> liftIO $ putStrLn $ "Error: " ++ err
                  Right response -> liftIO $ print $ encodeBytesForCLI $ BL.toStrict (BSC.pack (show response))
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

