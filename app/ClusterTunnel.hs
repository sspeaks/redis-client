{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module ClusterTunnel
  ( serveSmartProxy
  , servePinnedProxy
  ) where

import           Client                     (Client (..), ConnectionStatus (..))
import           Cluster                    (ClusterNode (..),
                                             ClusterTopology (..),
                                             NodeAddress (..), NodeRole (..))
import           ClusterCommandClient       (ClusterClient (..),
                                             ClusterError (..))
import qualified ClusterCommandClient
import           ClusterCommands            (CommandRouting (..),
                                             classifyCommand)
import           Connector                  (Connector)
import           Control.Concurrent         (MVar, forkIO, newEmptyMVar,
                                             putMVar, takeMVar)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (SomeException, bracket, finally,
                                             throwIO, try)
import           Control.Monad              (forever, void, when)
import qualified Control.Monad.State.Strict as State
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy       as LBS
import           Data.Char                  (isAlphaNum)
import           Data.List                  (isPrefixOf)
import qualified Data.Map.Strict            as Map
import           Data.Word                  (Word8)
import           Network.Socket             (Family (..), SockAddr (..), Socket,
                                             SocketOption (..), SocketType (..),
                                             bind, defaultProtocol, listen,
                                             setSocketOption, socket,
                                             tupleToHostAddress)
import qualified Network.Socket             as S
import           Network.Socket.ByteString  (recv, sendAll)
import           RedisCommandClient         (ClientState (..),
                                             RedisCommandClient, parseWith)
import qualified Resp
import           Resp                       (Encodable (encode), RespData (..))
import           System.IO                  (BufferMode (LineBuffering), hFlush,
                                             hSetBuffering, stdout)
import           Text.Printf                (printf)

-- | Smart proxy mode: Makes cluster appear as single Redis instance
-- Creates single listening socket and routes commands to appropriate nodes
serveSmartProxy :: (Client client) =>
  ClusterClient client ->
  IO ()
serveSmartProxy clusterClient = do
  hSetBuffering stdout LineBuffering
  bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
    setSocketOption sock ReuseAddr 1
    bind sock (SockAddrInet 6379 (tupleToHostAddress (127, 0, 0, 1)))
    listen sock 1024
    putStrLn "Smart proxy listening on localhost:6379"
    putStrLn "Cluster will appear as single Redis instance to clients"
    hFlush stdout

    -- Accept connections in a loop
    forever $ do
      (clientSock, clientAddr) <- S.accept sock
      printf "Accepted connection from %s\n" (show clientAddr)
      hFlush stdout

      -- Handle each client in a separate thread
      void $ forkIO $
        finally
          (handleSmartProxyClient clusterClient clientSock)
          (S.close clientSock)

-- | Handle a single client connection in smart proxy mode
handleSmartProxyClient :: (Client client) =>
  ClusterClient client ->
  Socket ->
  IO ()
handleSmartProxyClient clusterClient clientSock = do
  loop
  where
    loop = do
      -- Receive data from client
      dat <- recv clientSock 4096
      if BS.null dat
        then putStrLn "Client disconnected"
        else do
          -- Parse RESP command
          case Resp.parseStrict dat of
            Left err -> do
              printf "Failed to parse RESP: %s\n" err
              -- Send error back to client
              let errorResp = RespError (BS8.pack $ "ERR Failed to parse command: " ++ err)
              sendAll clientSock (LBS.toStrict $ Builder.toLazyByteString $ encode errorResp)
              loop
            Right respData -> do
              -- Route and execute the command
              result <- routeSmartProxyCommand clusterClient respData
              case result of
                Left err -> do
                  printf "Command execution error: %s\n" err
                  let errorResp = RespError (BS8.pack $ "ERR " ++ err)
                  sendAll clientSock (LBS.toStrict $ Builder.toLazyByteString $ encode errorResp)
                Right response -> do
                  -- Send response back to client
                  sendAll clientSock (LBS.toStrict $ Builder.toLazyByteString $ encode response)
              loop

-- | Route and execute a command in smart proxy mode
routeSmartProxyCommand :: (Client client) =>
  ClusterClient client ->
  RespData ->
  IO (Either String RespData)
routeSmartProxyCommand clusterClient respData = do
  case respData of
    RespArray (RespBulkString cmd : args) -> do
      let argKeys = [k | RespBulkString k <- args]
      case classifyCommand cmd argKeys of
        KeylessRoute   -> executeKeylessCommand clusterClient respData
        KeyedRoute key -> executeKeyedCommand clusterClient key respData
        CommandError e -> return $ Left e
    _ -> return $ Left "Expected array command"

-- | Execute a keyless command (route to any master)
executeKeylessCommand :: (Client client) =>
  ClusterClient client ->
  RespData ->
  IO (Either String RespData)
executeKeylessCommand clusterClient respData = do
  result <- ClusterCommandClient.executeKeylessClusterCommand
              clusterClient
              (sendRespCommand respData)
  return $ case result of
    Left err   -> Left (show err)
    Right resp -> Right resp

-- | Execute a keyed command (route by slot)
executeKeyedCommand :: (Client client) =>
  ClusterClient client ->
  BS.ByteString ->
  RespData ->
  IO (Either String RespData)
executeKeyedCommand clusterClient key respData = do
  result <- ClusterCommandClient.executeClusterCommand
              clusterClient
              key
              (sendRespCommand respData)
  return $ case result of
    Left (CrossSlotError msg) -> Left $ "CROSSSLOT error: " ++ msg
    Left err                  -> Left (show err)
    Right resp                -> Right resp

-- | Send RESP command via RedisCommandClient
sendRespCommand :: (Client client) => RespData -> RedisCommandClient client RespData
sendRespCommand respData = do
  ClientState client _ <- State.get
  let encoded = Builder.toLazyByteString $ encode respData
  send client encoded
  parseWith (receive client)

-- | Pinned proxy mode: One listener per cluster node
-- Each listener forwards to its corresponding cluster node
servePinnedProxy :: (Client client) =>
  ClusterClient client ->
  IO ()
servePinnedProxy clusterClient = do
  hSetBuffering stdout LineBuffering

  -- Get cluster topology
  topology <- readTVarIO (clusterTopology clusterClient)
  let masters = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
      connector = clusterConnector clusterClient

  when (null masters) $ do
    putStrLn "ERROR: No master nodes found in cluster topology"
    throwIO (userError "No master nodes in cluster")

  printf "Pinned proxy mode: Creating %d listeners for cluster nodes\n" (length masters)

  -- Create a listener for each master node
  mvars <- mapM (createPinnedListener connector) masters

  putStrLn "All pinned listeners started. Press Ctrl+C to stop."
  hFlush stdout

  -- Wait for all threads to complete (they won't unless there's an error)
  mapM_ takeMVar mvars

-- | Create a listener for a specific cluster node
createPinnedListener :: (Client client) =>
  Connector client ->
  ClusterNode ->
  IO (MVar ())
createPinnedListener connector node = do
  mvar <- newEmptyMVar
  let addr = nodeAddress node
      localPort = nodePort addr

  void $ forkIO $ do
    result <- try $ bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
      setSocketOption sock ReuseAddr 1
      bind sock (SockAddrInet (fromIntegral localPort) (tupleToHostAddress (127, 0, 0, 1)))
      listen sock 1024
      printf "Pinned listener on localhost:%d -> %s:%d\n"
        localPort (nodeHost addr) (nodePort addr)
      hFlush stdout

      -- Accept connections for this node
      forever $ do
        (clientSock, clientAddr) <- S.accept sock
        printf "[Port %d] Accepted connection from %s\n" localPort (show clientAddr)
        hFlush stdout

        -- Create dedicated connection for this pinned listener
        -- This is intentionally NOT using the connection pool because:
        -- 1. Pinned listeners maintain long-lived, persistent connections
        -- 2. Each listener needs its own connection tied to its lifecycle
        -- 3. Connection lifetime matches listener lifetime (closed when listener stops)
        redisConn <- connector addr

        -- Handle forwarding in a separate thread
        void $ forkIO $ do
          result <- try $ forwardPinnedConnection clientSock redisConn addr
          case result of
            Left (e :: SomeException) -> do
              printf "[Port %d] Forwarding error: %s\n" localPort (show e)
              hFlush stdout
            Right _ -> do
              printf "[Port %d] Forwarding completed normally\n" localPort
              hFlush stdout
          finally
            (do
              S.close clientSock
              close redisConn)
            (return ())

    case result of
      Left (e :: SomeException) -> do
        printf "Pinned listener on port %d failed: %s\n" localPort (show e)
        putMVar mvar ()
      Right _ -> putMVar mvar ()

  return mvar

-- | Forward traffic bidirectionally between client and cluster node
-- Also intercepts and rewrites cluster topology responses
-- Uses sequential request-response pattern to maintain proper ordering
forwardPinnedConnection :: (Client client) =>
  Socket ->
  client 'Connected ->
  NodeAddress ->
  IO ()
forwardPinnedConnection clientSock redisConn addr = do
  printf "[Pinned %s:%d] Starting forwarding loop\n" (nodeHost addr) (nodePort addr)
  hFlush stdout
  loop 1
  where
    loop :: Int -> IO ()
    loop reqNum = do
      -- Read command from client
      printf "[Pinned %s:%d] [Req %d] Waiting for client data...\n" (nodeHost addr) (nodePort addr) reqNum
      hFlush stdout

      -- Use try to catch any exceptions during recv
      result <- try $ recv clientSock 4096
      case result of
        Left (e :: SomeException) -> do
          printf "[Pinned %s:%d] [Req %d] Error receiving from client: %s\n"
            (nodeHost addr) (nodePort addr) reqNum (show e)
          hFlush stdout
          return ()  -- Exit loop on error
        Right dat ->
          if BS.null dat
            then do
              printf "[Pinned %s:%d] [Req %d] Client disconnected (received empty data)\n" (nodeHost addr) (nodePort addr) reqNum
              hFlush stdout
              return ()  -- Client disconnected
            else do
              printf "[Pinned %s:%d] [Req %d] Received %d bytes from client: %s\n"
                (nodeHost addr) (nodePort addr) reqNum (BS.length dat) (show $ BS.take 100 dat)
              hFlush stdout

              -- Forward to Redis
              printf "[Pinned %s:%d] [Req %d] Forwarding to Redis...\n" (nodeHost addr) (nodePort addr) reqNum
              hFlush stdout
              send redisConn (LBS.fromStrict dat)

              -- Receive response from Redis
              printf "[Pinned %s:%d] [Req %d] Waiting for Redis response...\n" (nodeHost addr) (nodePort addr) reqNum
              hFlush stdout
              response <- receive redisConn
              printf "[Pinned %s:%d] [Req %d] Received %d bytes from Redis: %s\n"
                (nodeHost addr) (nodePort addr) reqNum (BS.length response) (show $ BS.take 100 response)
              hFlush stdout

              -- Rewrite cluster responses
              -- In pinned mode, we rewrite topology responses to show 127.0.0.1
              -- This makes the cluster appear local while still allowing
              -- commands to be sent to any node (client handles MOVED errors)
              let rewritten = rewriteClusterResponse response
              if rewritten /= response
                then do
                  printf "[Pinned %s:%d] [Req %d] Response rewritten (original: %d bytes, rewritten: %d bytes)\n"
                    (nodeHost addr) (nodePort addr) reqNum (BS.length response) (BS.length rewritten)
                  hFlush stdout
                else do
                  printf "[Pinned %s:%d] [Req %d] Response not rewritten\n" (nodeHost addr) (nodePort addr) reqNum
                  hFlush stdout

              -- Send back to client
              printf "[Pinned %s:%d] [Req %d] Sending response back to client...\n" (nodeHost addr) (nodePort addr) reqNum
              hFlush stdout
              sendAll clientSock rewritten
              printf "[Pinned %s:%d] [Req %d] Response sent to client\n" (nodeHost addr) (nodePort addr) reqNum
              hFlush stdout

              -- Continue loop
              loop (reqNum + 1)

-- | Rewrite cluster responses to replace remote hosts with 127.0.0.1
-- Handles CLUSTER NODES, CLUSTER SLOTS, MOVED, and ASK responses
rewriteClusterResponse :: BS.ByteString -> BS.ByteString
rewriteClusterResponse dat =
  case Resp.parseStrict dat of
    Left _ -> dat  -- Can't parse, return as-is
    Right respData ->
      let rewritten = rewriteRespData respData
      in LBS.toStrict $ Builder.toLazyByteString $ encode rewritten

-- | Rewrite RespData to replace hosts with localhost
-- Handles three types of responses:
-- 1. MOVED/ASK errors: "MOVED slot host:port" -> "MOVED slot 127.0.0.1:port"
-- 2. CLUSTER NODES bulk strings: multi-line text with "node-id host:port@cport ..."
-- 3. CLUSTER SLOTS bulk strings: plain IPv4 addresses like "9.169.243.75"
rewriteRespData :: RespData -> RespData
rewriteRespData (RespError msg) =
  -- Handle MOVED and ASK errors: rewrite "host:port" to "127.0.0.1:port"
  let msgStr = BS8.unpack msg
  in if "MOVED" `isPrefixOf` msgStr || "ASK" `isPrefixOf` msgStr
    then RespError (BS8.pack $ rewriteRedirectionError msgStr)
    else RespError msg
rewriteRespData (RespBulkString bs) =
  let text = BS8.unpack bs
  in if isClusterNodesFormat text
       -- CLUSTER NODES format: multi-line text with node info
       then RespBulkString (rewriteClusterNodesText bs)
       -- Plain IPv4 address from CLUSTER SLOTS: replace with 127.0.0.1
       else if isIPv4Address text || isHostname text
              then RespBulkString "127.0.0.1"
              else RespBulkString bs

rewriteRespData (RespArray items) =
  -- Recursively rewrite array items (handles nested structures in CLUSTER SLOTS)
  RespArray (map rewriteRespData items)
rewriteRespData other = other

-- | Check if a bulk string is in CLUSTER NODES format
-- CLUSTER NODES format contains spaces and colons, e.g.:
-- "node-id host:port@cport flags master..."
isClusterNodesFormat :: String -> Bool
isClusterNodesFormat text = ' ' `elem` text && ':' `elem` text

-- | Check if a string is a valid IPv4 address
-- Uses the same parsing logic as Client.parseIPv4
-- Redis CLUSTER SLOTS responses contain IPv4 addresses, not hostnames
isIPv4Address :: String -> Bool
isIPv4Address str = case parseIPv4 str of
  Just _  -> True
  Nothing -> False
  where
    -- Parse IPv4 address string (e.g., "127.0.0.1")
    -- Copied from Client.hs to avoid circular dependencies
    parseIPv4 :: String -> Maybe ()
    parseIPv4 s = case words $ map (\c -> if c == '.' then ' ' else c) s of
      [a, b, c, d] -> do
        _ <- readMaybe a :: Maybe Word8
        _ <- readMaybe b :: Maybe Word8
        _ <- readMaybe c :: Maybe Word8
        _ <- readMaybe d :: Maybe Word8
        return ()
      _ -> Nothing

    readMaybe :: Read a => String -> Maybe a
    readMaybe s = case reads s of
      [(x, "")] -> Just x
      _         -> Nothing

-- | Check if a string is a hostname
-- A hostname must contain at least one dot and be alphanumeric with dots/hyphens
-- Examples: "redis1.local", "node1.cluster.local", "192.168.1.1" (but filtered by isIPv4Address)
isHostname :: String -> Bool
isHostname str =
  not (null str) &&
  not (isIPv4Address str) &&
  elem '.' str &&  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname  -- Must contain at least one dot to be a hostname
  all isAlphaNumOrDash str
  where
    isAlphaNumOrDash c = isAlphaNum c || c == '-' || c == '.'

-- | Rewrite MOVED/ASK error messages
rewriteRedirectionError :: String -> String
rewriteRedirectionError msg =
  -- MOVED 3999 host:port -> MOVED 3999 127.0.0.1:port
  -- ASK 3999 host:port -> ASK 3999 127.0.0.1:port
  let parts = words msg
  in case parts of
       [errType, slot, hostPort] ->
         case break (== ':') hostPort of
           (_, ':':port) -> errType ++ " " ++ slot ++ " 127.0.0.1:" ++ port
           _             -> msg
       _ -> msg

-- | Rewrite CLUSTER NODES response text
rewriteClusterNodesText :: BS.ByteString -> BS.ByteString
rewriteClusterNodesText bs =
  let text = BS8.unpack bs
      textLines = lines text
      rewritten = map rewriteClusterNodesLine textLines
  in BS8.pack (unlines rewritten)

-- | Rewrite a single line from CLUSTER NODES
rewriteClusterNodesLine :: String -> String
rewriteClusterNodesLine line =
  let parts = words line
  in case parts of
       (nodeId:hostPort:rest) ->
         case break (== ':') hostPort of
           (_, '@':_) ->
             -- Format: host:port@cport
             case break (== '@') hostPort of
               (hp, cport) ->
                 case break (== ':') hp of
                   (_, ':':port) ->
                     nodeId ++ " 127.0.0.1:" ++ port ++ cport ++ " " ++ unwords rest
                   _ -> line
           (_, ':':port) ->
             -- Format: host:port
             nodeId ++ " 127.0.0.1:" ++ port ++ " " ++ unwords rest
           _ -> line
       _ -> line

-- End of ClusterTunnel module
