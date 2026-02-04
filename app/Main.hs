{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (receive, send, connect),
                                             TLSClient (..), serve,
                                             PlainTextClient (..),
                                             ConnectionStatus (..))
import           Cluster                    (NodeAddress (..), NodeRole (..), 
                                             ClusterNode (..), ClusterTopology (..),
                                             topologyNodes, nodeRole, nodeAddress)
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..),
                                             ClusterCommandClient,
                                             ClusterClientState (..),
                                             ClusterError (..),
                                             createClusterClient,
                                             closeClusterClient,
                                             executeClusterCommand,
                                             executeKeylessClusterCommand,
                                             executeOnAllMasters,
                                             getMasterNodeCount,
                                             runClusterCommandClient)
import qualified ConnectionPool             as CP
import           ConnectionPool             (PoolConfig (PoolConfig))
import           Control.Concurrent         (forkIO, newEmptyMVar, putMVar,
                                             takeMVar)
import           Control.Monad.IO.Class
import qualified Control.Monad.State.Strict as State
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Word                  (Word64, Word16)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import qualified Data.Vector                as V
import           Control.Concurrent.STM     (readTVarIO)
import           Filler                     (fillCacheWithData,
                                             fillCacheWithDataMB,
                                             fillCacheWithDataCluster,
                                             fillCacheWithDataClusterPipelined,
                                             initRandomNoise)
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommandClient,
                                             RedisCommands (flushAll),
                                             RunState (..), parseWith,
                                             runCommandsAgainstPlaintextHost,
                                             runCommandsAgainstTLSHost)
import           Resp                       (Encodable (encode),
                                             RespData (RespArray, RespBulkString, RespError),
                                             parseRespData)
import qualified Resp
import qualified Data.Attoparsec.ByteString as Atto
import           Control.Exception          (SomeException, bracket, finally, handle)
import           Control.Monad              (forever, unless, void, when)
import qualified Data.ByteString            as B
import           Data.ByteString.Lazy       (fromStrict)
import           Network.Socket             (AddrInfo (..), Family (AF_INET),
                                             Socket, SocketOption (..),
                                             SocketType (Stream), SockAddr (SockAddrInet),
                                             defaultProtocol,
                                             setSocketOption, socket, tupleToHostAddress)
import qualified Network.Socket             as S
import           Network.Socket.ByteString  (recv)
import           Network.Socket.ByteString.Lazy (sendAll)
import           System.IO                  (hFlush, hIsTerminalDevice, isEOF, stdin, stdout)
import           System.Console.GetOpt      (ArgDescr (..), ArgOrder (..),
                                             OptDescr (Option), getOpt,
                                             usageInfo)
import           System.Console.Readline    (addHistory, readline)
import           System.Environment         (getArgs)
import           System.Exit                (exitFailure, exitSuccess)
import           System.Random              (randomIO)
import           Text.Printf                (printf)

defaultRunState :: RunState
defaultRunState = RunState "" Nothing "default" "" False 0 False False (Just 2) False "smart"

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
    Option [] ["tunnel-mode"] (ReqArg (\arg opt -> return $ opt {tunnelMode = arg}) "MODE") "Tunnel mode: 'smart' (default) or 'pinned'"
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
      putStrLn "Environment Variables for Performance Tuning:"
      putStrLn "  REDIS_CLIENT_FILL_CHUNK_KB    Chunk size in KB (default: 8192)"
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  redis-client fill -h localhost -d 5                     # Fill 5GB standalone"
      putStrLn "  redis-client fill -h node1 -d 5 -c                      # Fill 5GB cluster"
      putStrLn "  redis-client cli -h localhost -c                        # CLI with cluster"
      putStrLn "  redis-client tunn -h node1 -t -c --tunnel-mode smart    # Smart cluster proxy"
      putStrLn "  REDIS_CLIENT_FILL_CHUNK_KB=4096 redis-client fill ...   # Use 4MB chunks"
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

-- | Create cluster connector for plaintext connections
createPlaintextConnector :: RunState -> (NodeAddress -> IO (PlainTextClient 'Connected))
createPlaintextConnector _ = \addr -> do
  let notConnected = NotConnectedPlainTextClient (nodeHost addr) (Just $ nodePort addr)
  connect notConnected

-- | Create cluster connector for TLS connections
createTLSConnector :: RunState -> (NodeAddress -> IO (TLSClient 'Connected))
createTLSConnector _ = \addr -> do
  let notConnected = NotConnectedTLSClient (nodeHost addr) (Just $ nodePort addr)
  connect notConnected

-- | Create a cluster client from RunState
createClusterClientFromState :: (Client client) => 
  RunState -> 
  (NodeAddress -> IO (client 'Connected)) -> 
  IO (ClusterClient client)
createClusterClientFromState state connector = do
  let defaultPort = if useTLS state then 6380 else 6379
      seedNode = NodeAddress (host state) (maybe defaultPort id (port state))
      poolConfig = PoolConfig
        { CP.maxConnectionsPerNode = 10  -- Max connections per node
        , CP.connectionTimeout = 300     -- 5 minutes timeout
        , CP.maxRetries = 3
        , CP.useTLS = useTLS state
        }
      clusterCfg = ClusterConfig
        { clusterSeedNode = seedNode
        , clusterPoolConfig = poolConfig
        , clusterMaxRetries = 3
        , clusterRetryDelay = 100000  -- 100ms
        , clusterTopologyRefreshInterval = 60
        }
  createClusterClient clusterCfg connector

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
  case tunnelMode state of
    "smart" -> tunnClusterSmart state
    "pinned" -> tunnClusterPinned state
    _ -> do
      printf "Invalid tunnel mode '%s'. Valid modes: smart, pinned\n" (tunnelMode state)
      exitFailure

tunnClusterSmart :: RunState -> IO ()
tunnClusterSmart state = do
  if not (useTLS state)
    then do
      putStrLn "Smart cluster proxy mode (plaintext)"
      putStrLn "Note: This is a basic implementation that forwards commands to appropriate cluster nodes."
      putStrLn "Each incoming connection creates its own cluster client for routing."
      
      -- Create the initial cluster client to verify connectivity
      testClient <- createClusterClientFromState state (createPlaintextConnector state)
      closeClusterClient testClient
      putStrLn "Cluster connectivity verified"
      
      -- Start the proxy server
      bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
        setSocketOption sock ReuseAddr 1
        S.bind sock (SockAddrInet 6379 (tupleToHostAddress (127, 0, 0, 1)))
        S.listen sock 1024
        putStrLn "Listening on localhost:6379"
        hFlush stdout
        forever $ do
          (clientSock, _) <- S.accept sock
          putStrLn "Accepted connection from client"
          hFlush stdout
          _ <- forkIO $ handle (\(e :: SomeException) -> do
              putStrLn $ "Client connection error: " ++ show e
              S.close clientSock
            ) $ do
            -- Each connection gets its own cluster client
            clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
            finally
              (proxyClusterConnection clientSock clusterClient (createPlaintextConnector state))
              (do
                S.close clientSock
                closeClusterClient clusterClient
              )
          return ()
    else do
      putStrLn "TLS tunnel to cluster not yet implemented."
      putStrLn "Use plaintext mode or wait for future enhancements."
      exitFailure
  where
    -- Proxy a single client connection through the cluster
    proxyClusterConnection :: Socket -> ClusterClient PlainTextClient -> (NodeAddress -> IO (PlainTextClient 'Connected)) -> IO ()
    proxyClusterConnection clientSock clusterClient connector = loop
      where
        loop = do
          -- Receive command from client
          dat <- recv clientSock 4096
          when (not $ B.null dat) $ do
            -- Parse the RESP command to determine routing
            case Atto.parseOnly parseRespData (B.toStrict $ fromStrict dat) of
              Right respCommand -> do
                -- Execute through cluster client
                result <- executeRespCommand clusterClient connector respCommand
                case result of
                  Right response -> do
                    -- Send response back to client
                    let responseBytes = Builder.toLazyByteString $ encode response
                    sendAll clientSock responseBytes
                  Left err -> do
                    -- Send error back to client
                    let errorMsg = RespError $ "ERR Cluster proxy error: " ++ show err
                        errorBytes = Builder.toLazyByteString $ encode errorMsg
                    sendAll clientSock errorBytes
              Left err -> do
                -- Send parse error back to client
                let errorMsg = RespError $ "ERR Parse error: " ++ err
                    errorBytes = Builder.toLazyByteString $ encode errorMsg
                sendAll clientSock errorBytes
            loop
    
    -- Execute a RESP command through the cluster
    executeRespCommand :: ClusterClient PlainTextClient -> (NodeAddress -> IO (PlainTextClient 'Connected)) -> RespData -> IO (Either ClusterError RespData)
    executeRespCommand client connector respCommand = do
      case respCommand of
        RespArray (RespBulkString cmdName : args) -> do
          let cmdUpper = LB.map toUpperChar cmdName
              -- Helper to create RedisCommandClient action that sends raw command
              sendRaw = do
                ClientState conn _ <- State.get
                send conn (Builder.toLazyByteString $ encode respCommand)
                parseWith (receive conn)
          
          -- Route based on command type
          if cmdUpper `elem` keylessCommands
            then executeKeylessClusterCommand client sendRaw connector
            else case args of
              (RespBulkString key : _) -> 
                executeClusterCommand client (LB.toStrict key) sendRaw connector
              _ -> executeKeylessClusterCommand client sendRaw connector
        _ -> return $ Left $ ConnectionError "Invalid command format"
    
    -- Commands that don't require a key for routing (as Lazy ByteStrings)
    keylessCommands = 
      [ "PING", "AUTH", "FLUSHALL", "FLUSHDB", "DBSIZE", "INFO"
      , "CLUSTER", "CONFIG", "CLIENT", "COMMAND", "ECHO", "QUIT"
      ]
    
    -- Convert character to uppercase
    toUpperChar :: Char -> Char
    toUpperChar c
      | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
      | otherwise = c

tunnClusterPinned :: RunState -> IO ()
tunnClusterPinned state = do
  putStrLn "Pinned mode: Connection forwarding to seed node"
  putStrLn "Note: This is a basic implementation for Phase 3."
  putStrLn "A full implementation would forward connections through the cluster client."
  putStrLn "Future enhancement: Implement proper connection forwarding with cluster routing."
  if useTLS state
    then do
      -- Note: For Phase 3, we demonstrate the structure but acknowledge
      -- that full tunnel implementation requires more work
      putStrLn "TLS tunnel to cluster not fully implemented."
      putStrLn "Use standalone tunnel mode or wait for Phase 5 enhancements."
    else do
      putStrLn "Tunnel mode is only supported with TLS enabled\n"
      exitFailure

fill :: RunState -> IO ()
fill state = do
  when (dataGBs state <= 0 && not (flush state)) $ do
    putStrLn "No data specified or data is 0GB or fewer\n"
    putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
    exitFailure
  
  if useCluster state
    then fillCluster state
    else fillStandalone state
  
  -- Exit with success only if we filled data, otherwise failure
  -- This maintains the original behavior where flush-only exits with failure
  when (dataGBs state > 0) exitSuccess
  exitFailure

fillStandalone :: RunState -> IO ()
fillStandalone state = do
  when (flush state) $ do
    printf "Flushing cache '%s'\n" (host state)
    if useTLS state
      then runCommandsAgainstTLSHost state (void flushAll)
      else runCommandsAgainstPlaintextHost state (void flushAll)
  when (dataGBs state > 0) $ do
    initRandomNoise -- Ensure noise buffer is initialized once and shared
    baseSeed <- randomIO :: IO Word64
    if serial state
      then do
        printf "Filling cache '%s' with %dGB of data using serial mode\n" (host state) (dataGBs state)
        if useTLS state
          then runCommandsAgainstTLSHost state $ fillCacheWithData baseSeed 0 (dataGBs state)
          else runCommandsAgainstPlaintextHost state $ fillCacheWithData baseSeed 0 (dataGBs state)
      else do
        -- Use numConnections (defaults to 8)
        let nConns = maybe 8 id (numConnections state)
            totalMB = dataGBs state * 1024  -- Work in MB for finer granularity
            baseMB = totalMB `div` nConns
            remainder = totalMB `mod` nConns
            -- Each connection gets (baseMB + 1) or baseMB MB
            -- Jobs: (connectionIdx, mbForThisConnection)
            jobs = [(i, if i < remainder then baseMB + 1 else baseMB) | i <- [0..nConns - 1], baseMB > 0 || i < remainder]
        printf "Filling cache '%s' with %dGB of data using %d parallel connections\n" (host state) (dataGBs state) (length jobs)
        mvars <- mapM (\(idx, mb) -> do
            mv <- newEmptyMVar
            _ <- forkIO $ do
                 if useTLS state
                    then runCommandsAgainstTLSHost state $ fillCacheWithDataMB baseSeed idx mb
                    else runCommandsAgainstPlaintextHost state $ fillCacheWithDataMB baseSeed idx mb
                 putMVar mv ()
            return mv) jobs
        mapM_ takeMVar mvars

fillCluster :: RunState -> IO ()
fillCluster state = do
  when (flush state) $ do
    printf "Flushing cluster cache (all master nodes)\n"
    if useTLS state
      then do
        clusterClient <- createClusterClientFromState state (createTLSConnector state)
        result <- executeOnAllMasters clusterClient (void flushAll) (createTLSConnector state)
        case result of
          Right _ -> putStrLn "Successfully flushed all master nodes"
          Left err -> putStrLn $ "Error flushing cluster: " ++ show err
        closeClusterClient clusterClient
      else do
        clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
        result <- executeOnAllMasters clusterClient (void flushAll) (createPlaintextConnector state)
        case result of
          Right _ -> putStrLn "Successfully flushed all master nodes"
          Left err -> putStrLn $ "Error flushing cluster: " ++ show err
        closeClusterClient clusterClient
  
  when (dataGBs state > 0) $ do
    initRandomNoise -- Ensure noise buffer is initialized once and shared
    baseSeed <- randomIO :: IO Word64
    
    if serial state
      then do
        printf "Filling cluster cache with %dGB of data using serial mode (non-pipelined)\n" (dataGBs state)
        -- Serial mode uses the non-pipelined version for simplicity
        if useTLS state
          then do
            clusterClient <- createClusterClientFromState state (createTLSConnector state)
            runClusterCommandClient clusterClient (createTLSConnector state) $ 
              fillCacheWithDataCluster baseSeed 0 (dataGBs state * 1024)
            closeClusterClient clusterClient
          else do
            clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
            runClusterCommandClient clusterClient (createPlaintextConnector state) $ 
              fillCacheWithDataCluster baseSeed 0 (dataGBs state * 1024)
            closeClusterClient clusterClient
      else do
        -- Parallel mode with pipelining: discover topology and distribute work by slots
        printf "Discovering cluster topology for pipelined fill...\n"
        
        -- Create temporary client to get cluster info
        (masterCount, topology) <- if useTLS state
          then do
            tempClient <- createClusterClientFromState state (createTLSConnector state)
            topo <- readTVarIO (clusterTopology tempClient)
            count <- getMasterNodeCount tempClient
            closeClusterClient tempClient
            return (count, topo)
          else do
            tempClient <- createClusterClientFromState state (createPlaintextConnector state)
            topo <- readTVarIO (clusterTopology tempClient)
            count <- getMasterNodeCount tempClient
            closeClusterClient tempClient
            return (count, topo)
        
        -- Default to 2 threads per master node
        let defaultConns = if numConnections state == Just 2
              then Nothing
              else numConnections state
            threadsPerNode = 2
            nConns = maybe (masterCount * threadsPerNode) id defaultConns
            totalMB = dataGBs state * 1024
            -- Distribute MB evenly: base amount per thread + 1 extra for first 'remainder' threads
            -- Example: 1024MB / 6 threads = 170 base + 4 remainder
            -- First 4 threads get 171MB, last 2 get 170MB
            -- Total: 4*171 + 2*170 = 684 + 340 = 1024MB ✓
            mbPerThread = totalMB `div` nConns
            remainder = totalMB `mod` nConns
        
        -- Distribute slots evenly across threads
        -- Each thread gets assigned specific slots to ensure pipelining works
        let slotsPerThread = max 1 (16384 `div` nConns)
            threadJobs = [(threadIdx, 
                          threadIdx * slotsPerThread,  -- startSlot
                          if threadIdx == nConns - 1 then 16383 else (threadIdx + 1) * slotsPerThread - 1,  -- endSlot
                          if threadIdx < remainder then mbPerThread + 1 else mbPerThread)
                         | threadIdx <- [0..nConns - 1], mbPerThread > 0 || threadIdx < remainder]
        
        printf "Filling cluster with %dGB using %d threads (%d master nodes, %d threads per node) with pipelining\n" 
          (dataGBs state) (length threadJobs) masterCount threadsPerNode
        
        -- Create jobs with pipelined fill
        mvars <- mapM (\(threadIdx, startSlot, _endSlot, mb) -> do
            mv <- newEmptyMVar
            _ <- forkIO $ do
                 -- Use the start slot in this thread's range for the hash tag
                 let targetSlot = fromIntegral startSlot :: Word16
                     nodeId = (topologySlots topology) V.! fromIntegral targetSlot
                     nodesById = topologyNodes topology
                 case Map.lookup nodeId nodesById of
                   Just node -> do
                     let addr = nodeAddress node
                     if useTLS state
                       then do
                         conn <- createTLSConnector state addr
                         fillCacheWithDataClusterPipelined baseSeed threadIdx mb targetSlot conn
                       else do
                         conn <- createPlaintextConnector state addr
                         fillCacheWithDataClusterPipelined baseSeed threadIdx mb targetSlot conn
                   Nothing -> printf "Warning: No node found for slot %d (node ID: %s)\n" targetSlot (show nodeId)
                 putMVar mv ()
            return mv) threadJobs
        mapM_ takeMVar mvars
        
        printf "Cluster fill with pipelining complete.\n"

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
      runClusterCommandClient clusterClient (createTLSConnector state) (replCluster isTTY)
      closeClusterClient clusterClient
    else do
      clusterClient <- createClusterClientFromState state (createPlaintextConnector state)
      putStrLn $ "Connected to cluster seed node: " ++ host state
      runClusterCommandClient clusterClient (createPlaintextConnector state) (replCluster isTTY)
      closeClusterClient clusterClient

repl :: (Client client) => Bool -> RedisCommandClient client ()
repl isTTY = do
  ClientState !client _ <- State.get
  loop client
  where
    loop !client = do
      command <- liftIO readCommand
      case command of
        Nothing -> return ()
        Just cmd -> do
          when isTTY $ liftIO $ addHistory cmd
          unless (cmd == "exit") $ do
            (send client . Builder.toLazyByteString . encode . RespArray . map (RespBulkString . BS.pack)) . words $ cmd
            response <- parseWith (receive client)
            liftIO $ print response
            loop client
    readCommand
      | isTTY = readline "> "
      | otherwise = do
          eof <- isEOF
          if eof
            then return Nothing
            else Just <$> getLine

-- | REPL for cluster mode - uses ClusterCommandClient
replCluster :: (Client client) => Bool -> ClusterCommandClient client ()
replCluster isTTY = loop
  where
    loop = do
      command <- liftIO readCommand
      case command of
        Nothing -> return ()
        Just cmd -> do
          when isTTY $ liftIO $ addHistory cmd
          unless (cmd == "exit") $ do
            -- Parse the command into RESP format
            let cmdWords = words cmd
            case cmdWords of
              [] -> loop
              _ -> do
                -- Build a RESP array from the command words
                let respCommand = RespArray $ map (RespBulkString . BS.pack) cmdWords
                
                -- Get the cluster client state to execute raw commands
                ClusterClientState client connector <- State.get
                
                -- Execute the command - we need to determine if it's keyed or keyless
                result <- liftIO $ executeRawCommand client connector respCommand
                
                case result of
                  Right response -> liftIO $ print response
                  Left err -> liftIO $ putStrLn $ "Error: " ++ show err
                
                loop
    readCommand
      | isTTY = readline "> "
      | otherwise = do
          eof <- liftIO isEOF
          if eof
            then return Nothing
            else liftIO $ Just <$> getLine
    
    -- Execute a raw RESP command, extracting keys if needed
    executeRawCommand :: (Client client) => 
      ClusterClient client -> 
      (NodeAddress -> IO (client 'Connected)) -> 
      RespData -> 
      IO (Either ClusterError RespData)
    executeRawCommand client connector respCommand = do
      case respCommand of
        RespArray (RespBulkString cmdName : args) -> do
          let cmdUpper = LB.map toUpperChar cmdName
              -- Helper to create RedisCommandClient action that sends raw command
              sendRaw = do
                ClientState conn _ <- State.get
                send conn (Builder.toLazyByteString $ encode respCommand)
                parseWith (receive conn)
          
          -- Route based on command type
          if cmdUpper `elem` keylessCommands
            then executeKeylessClusterCommand client sendRaw connector
            else case args of
              (RespBulkString key : _) -> 
                executeClusterCommand client (LB.toStrict key) sendRaw connector
              _ -> executeKeylessClusterCommand client sendRaw connector
        _ -> return $ Left $ ConnectionError "Invalid command format"
    
    -- Commands that don't require a key for routing (as Lazy ByteStrings)
    keylessCommands = 
      [ "PING", "AUTH", "FLUSHALL", "FLUSHDB", "DBSIZE", "INFO"
      , "CLUSTER", "CONFIG", "CLIENT", "COMMAND", "ECHO", "QUIT"
      ]
    
    -- Convert character to uppercase
    toUpperChar :: Char -> Char
    toUpperChar c
      | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
      | otherwise = c
