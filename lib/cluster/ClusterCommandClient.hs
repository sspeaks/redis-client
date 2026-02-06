{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module ClusterCommandClient
  ( -- * Client Types
    ClusterClient (..),
    ClusterCommandClient,
    ClusterClientState (..),
    ClusterError (..),
    ClusterConfig (..),
    -- * Client Lifecycle
    createClusterClient,
    closeClusterClient,
    refreshTopology,
    -- * Running Commands
    runClusterCommandClient,
    executeClusterCommand,
    executeKeylessClusterCommand,
    -- * Re-export RedisCommands for convenience
    module RedisCommandClient,
    -- * Internal (exported for testing)
    RedirectionInfo (..),
    parseRedirectionError,
  )
where

import           Client                      (Client (..),
                                              ConnectionStatus (..),
                                              PlainTextClient (NotConnectedPlainTextClient),
                                              TLSClient (NotConnectedTLSClient))
import           Cluster                     (ClusterNode (..),
                                              ClusterTopology (..),
                                              NodeAddress (..), NodeRole (..),
                                              calculateSlot, findNodeForSlot,
                                              parseClusterSlots)
import           ConnectionPool              (ConnectionPool, PoolConfig (..),
                                              closePool, createPool,
                                              getOrCreateConnection)
import           Control.Concurrent          (threadDelay)
import           Control.Concurrent.STM      (TVar, atomically,
                                              newTVarIO, readTVar, readTVarIO, writeTVar)
import           Control.Exception           (SomeException, catch, throwIO,
                                              try)
import           Control.Monad               (when)
import           Control.Monad.IO.Class      (MonadIO (..))
import qualified Control.Monad.State         as State
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Builder     as Builder
import qualified Data.ByteString.Char8       as BS
import qualified Data.ByteString.Lazy.Char8  as BSC
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Time.Clock             (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import qualified Data.Vector                 as V
import           Data.Word                   (Word16)
import qualified RedisCommandClient
import           RedisCommandClient          (ClientState (..),
                                              RedisCommandClient (..),
                                              RedisCommands (..), parseWith,
                                              runRedisCommandClient)
import           Resp                        (Encodable (..), RespData (..))

-- | Error types specific to cluster operations
data ClusterError
  = MovedError Word16 NodeAddress -- Slot and new address
  | AskError Word16 NodeAddress -- Slot and temporary address
  | ClusterDownError String
  | TryAgainError String
  | CrossSlotError String
  | MaxRetriesExceeded String
  | TopologyError String
  | ConnectionError String
  deriving (Show, Eq)

-- | Redirection information parsed from errors
data RedirectionInfo = RedirectionInfo
  { redirSlot :: Word16,
    redirHost :: String,
    redirPort :: Int
  }
  deriving (Show, Eq)

-- | Configuration for cluster client
data ClusterConfig = ClusterConfig
  { clusterSeedNode                :: NodeAddress, -- Initial node to connect to
    clusterPoolConfig              :: PoolConfig,
    clusterMaxRetries              :: Int, -- Maximum retry attempts (default: 3)
    clusterRetryDelay              :: Int, -- Initial retry delay in microseconds (default: 100000 = 100ms)
    clusterTopologyRefreshInterval :: Int -- Seconds between topology refreshes (default: 600 = 10 minutes)
  }
  deriving (Show)

-- | Cluster client that manages connections to multiple nodes
data ClusterClient client = ClusterClient
  { clusterTopology       :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig         :: ClusterConfig
  }

-- | State for ClusterCommandClient monad
data ClusterClientState client = ClusterClientState
  { getClusterClient :: ClusterClient client,
    getConnector     :: NodeAddress -> IO (client 'Connected)
  }

-- | Monad for executing Redis commands on a cluster
-- Wraps StateT to abstract away the client state and connector
data ClusterCommandClient client a where
  ClusterCommandClient :: (Client client) =>
    { runClusterCommandClientM :: State.StateT (ClusterClientState client) IO a }
    -> ClusterCommandClient client a

-- | Run a ClusterCommandClient action with the given cluster client and connector
runClusterCommandClient ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  ClusterCommandClient client a ->
  IO a
runClusterCommandClient client connector (ClusterCommandClient action) = do
  let state = ClusterClientState client connector
  State.evalStateT action state

instance (Client client) => Functor (ClusterCommandClient client) where
  fmap :: (a -> b) -> ClusterCommandClient client a -> ClusterCommandClient client b
  fmap f (ClusterCommandClient s) = ClusterCommandClient (fmap f s)

instance (Client client) => Applicative (ClusterCommandClient client) where
  pure :: a -> ClusterCommandClient client a
  pure = ClusterCommandClient . pure
  (<*>) :: ClusterCommandClient client (a -> b) -> ClusterCommandClient client a -> ClusterCommandClient client b
  ClusterCommandClient f <*> ClusterCommandClient s = ClusterCommandClient (f <*> s)

instance (Client client) => Monad (ClusterCommandClient client) where
  (>>=) :: ClusterCommandClient client a -> (a -> ClusterCommandClient client b) -> ClusterCommandClient client b
  ClusterCommandClient s >>= f = ClusterCommandClient (s >>= \a -> let ClusterCommandClient s' = f a in s')

instance (Client client) => MonadIO (ClusterCommandClient client) where
  liftIO :: IO a -> ClusterCommandClient client a
  liftIO = ClusterCommandClient . liftIO

instance (Client client) => State.MonadState (ClusterClientState client) (ClusterCommandClient client) where
  get :: ClusterCommandClient client (ClusterClientState client)
  get = ClusterCommandClient State.get
  put :: ClusterClientState client -> ClusterCommandClient client ()
  put = ClusterCommandClient . State.put

instance (Client client) => MonadFail (ClusterCommandClient client) where
  fail :: String -> ClusterCommandClient client a
  fail = ClusterCommandClient . liftIO . Prelude.fail

-- | Create a new cluster client by connecting to seed node and discovering topology
createClusterClient ::
  (Client client) =>
  ClusterConfig ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (ClusterClient client)
createClusterClient config connector = do
  pool <- createPool (clusterPoolConfig config)
  
  -- Discover initial topology before creating TVar
  let seedNode = clusterSeedNode config
  conn <- getOrCreateConnection pool seedNode connector
  let clientState = ClientState conn BS.empty
  response <- State.evalStateT (runRedisCommandClient clusterSlots) clientState
  
  currentTime <- getCurrentTime
  case parseClusterSlots response currentTime of
    Left err -> throwIO $ userError $ "Failed to parse cluster topology: " <> err
    Right initialTopology -> do
      topology <- newTVarIO initialTopology
      return $ ClusterClient topology pool config

-- | Close all connections in the cluster client
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = closePool (clusterConnectionPool client)

-- | Refresh cluster topology by querying CLUSTER SLOTS
-- This is called automatically when:
-- 1. Topology is stale (older than clusterTopologyRefreshInterval)
-- 2. A MOVED error is encountered (indicates topology changed)
--
-- Performance: ~1-5ms per refresh (network + parsing cost)
-- Note: Multiple concurrent refreshes may occur during cluster reconfiguration.
-- Consider implementing refresh rate limiting in high-concurrency scenarios.
refreshTopology ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO ()
refreshTopology client connector = do
  let seedNode = clusterSeedNode (clusterConfig client)
  conn <- getOrCreateConnection (clusterConnectionPool client) seedNode connector

  -- Use clusterSlots command from RedisCommands
  let clientState = ClientState conn BS.empty
  response <- State.evalStateT (runRedisCommandClient clusterSlots) clientState

  currentTime <- getCurrentTime
  case parseClusterSlots response currentTime of
    Left err -> throwIO $ userError $ "Failed to parse cluster topology: " <> err
    Right topology -> atomically $ writeTVar (clusterTopology client) topology

-- | Check if topology is stale and refresh if needed
-- Called before every keyed command execution.
-- Performance: ~100-500ns (non-blocking read + time check)
-- Only triggers refresh when topology is older than clusterTopologyRefreshInterval.
refreshTopologyIfStale ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO ()
refreshTopologyIfStale client connector = do
  topology <- readTVarIO (clusterTopology client)
  currentTime <- getCurrentTime
  let timeSinceUpdate = diffUTCTime currentTime (topologyUpdateTime topology)
      refreshInterval = fromIntegral (clusterTopologyRefreshInterval (clusterConfig client)) :: NominalDiffTime
  when (timeSinceUpdate >= refreshInterval) $ do
    refreshTopology client connector

-- | Detect MOVED or ASK errors from RespData
detectRedirection :: RespData -> Maybe (Either RedirectionInfo RedirectionInfo)
detectRedirection (RespError msg) =
  case parseRedirectionError "MOVED" msg of
       Just redir -> Just (Left redir)  -- Left for MOVED
       Nothing -> case parseRedirectionError "ASK" msg of
         Just redir -> Just (Right redir)  -- Right for ASK
         Nothing -> Nothing
detectRedirection _ = Nothing

-- | Execute a Redis command with cluster awareness and automatic redirection handling
executeClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  ByteString -> -- The key to determine routing
  RedisCommandClient client RespData ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError RespData)
executeClusterCommand client key action connector = do
  -- Refresh topology if it's stale
  refreshTopologyIfStale client connector
  
  slot <- calculateSlot key
  withRetryAndRefresh client connector (clusterMaxRetries (clusterConfig client)) (clusterRetryDelay (clusterConfig client)) $ do
    executeOnSlot client slot action connector

-- | Execute a command on the node responsible for a given slot
executeOnSlot ::
  (Client client) =>
  ClusterClient client ->
  Word16 ->
  RedisCommandClient client RespData ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError RespData)
executeOnSlot client slot action connector = do
  topology <- readTVarIO (clusterTopology client)
  case findNodeForSlot topology slot of
    Nothing -> return $ Left $ TopologyError $ "No node found for slot " ++ show slot
    Just nodeId -> do
      -- Look up the node address from the topology
      case Map.lookup nodeId (topologyNodes topology) of
        Nothing -> return $ Left $ TopologyError $ "Node ID " ++ T.unpack nodeId ++ " not found in topology"
        Just node -> executeOnNodeWithRedirectionDetection client (nodeAddress node) action connector

-- | Execute a command on a specific node
executeOnNode ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
executeOnNode client nodeAddr action connector = do
  result <- try $ do
    conn <- getOrCreateConnection (clusterConnectionPool client) nodeAddr connector
    let clientState = ClientState conn BS.empty
    State.evalStateT (runRedisCommandClient action) clientState

  case result of
    Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
    Right value               -> return $ Right value

-- | Execute a command on a specific node with RespData return type,
-- detecting MOVED/ASK errors from the response
executeOnNodeWithRedirectionDetection ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client RespData ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError RespData)
executeOnNodeWithRedirectionDetection client nodeAddr action connector = do
  result <- executeOnNode client nodeAddr action connector
  case result of
    Right respData -> case detectRedirection respData of
      Just (Left (RedirectionInfo slot host port)) ->
        return $ Left $ MovedError slot (NodeAddress host port)
      Just (Right (RedirectionInfo slot host port)) ->
        return $ Left $ AskError slot (NodeAddress host port)
      Nothing -> return $ Right respData
    Left err -> return $ Left err

-- | Execute a keyless command on any available node (e.g., PING, AUTH, FLUSHALL)
executeKeylessClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
executeKeylessClusterCommand client action connector = do
  topology <- readTVarIO (clusterTopology client)
  -- Find any master node to execute the command on
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  case masterNodes of
    []       -> return $ Left $ TopologyError "No master nodes available"
    (node:_) -> executeOnNode client (nodeAddress node) action connector

-- | Retry logic with exponential backoff
withRetry ::
  Int -> -- Max retries
  Int -> -- Initial delay (microseconds)
  IO (Either ClusterError a) ->
  IO (Either ClusterError a)
withRetry maxRetries initialDelay action = go 0 initialDelay
  where
    go attempt delay
      | attempt >= maxRetries = return $ Left $ MaxRetriesExceeded $ "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action
          case result of
            Left (TryAgainError msg) -> do
              -- Exponential backoff
              threadDelay delay
              go (attempt + 1) (delay * 2)
            Left err@(MovedError _ _) -> return $ Left err -- These should be handled at a higher level
            Left err@(AskError _ _) -> return $ Left err
            Left err -> return $ Left err
            Right value -> return $ Right value

-- | Retry logic with exponential backoff and topology refresh on MOVED errors
-- 
-- MOVED errors trigger immediate topology refresh and retry. This ensures the client
-- quickly adapts to cluster topology changes (e.g., slot migrations, node failures).
--
-- Performance considerations:
-- - During cluster reconfiguration, multiple MOVED errors may trigger concurrent refreshes
-- - Each refresh costs ~1-5ms (network + parsing)
-- - For clusters with high concurrency and frequent rebalancing, consider implementing
--   refresh rate limiting or deduplication to prevent refresh storms
--
-- ASK errors (temporary redirects) retry without refresh since they don't indicate
-- permanent topology changes.
withRetryAndRefresh ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  Int -> -- Max retries
  Int -> -- Initial delay (microseconds)
  IO (Either ClusterError a) ->
  IO (Either ClusterError a)
withRetryAndRefresh client connector maxRetries initialDelay action = go 0 initialDelay
  where
    go attempt delay
      | attempt >= maxRetries = return $ Left $ MaxRetriesExceeded $ "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action
          case result of
            Left (TryAgainError msg) -> do
              -- Exponential backoff
              threadDelay delay
              go (attempt + 1) (delay * 2)
            Left (MovedError slot addr) -> do
              -- MOVED error indicates topology changed, refresh and retry
              refreshTopology client connector
              go (attempt + 1) delay
            Left (AskError slot addr) -> do
              -- ASK is temporary, just retry without refresh
              -- TODO: Implement ASKING command handling
              threadDelay delay
              go (attempt + 1) delay
            Left err -> return $ Left err
            Right value -> return $ Right value

-- | Parse redirection error messages
-- Format: "MOVED 3999 127.0.0.1:6381" or "ASK 3999 127.0.0.1:6381"
parseRedirectionError :: String -> String -> Maybe RedirectionInfo
parseRedirectionError errorType msg =
  case words msg of
    (prefix : slotStr : hostPort : _)
      | prefix == errorType ->
          case reads slotStr of
            [(slot, "")] ->
              case break (== ':') hostPort of
                (host, ':' : portStr) ->
                  case reads portStr of
                    [(port, "")] -> Just $ RedirectionInfo (fromIntegral slot) host port
                    _ -> Nothing
                _ -> Nothing
            _ -> Nothing
    _ -> Nothing

-- | Internal helper to execute a keyed command within ClusterCommandClient monad
executeKeyedCommand ::
  (Client client) =>
  ByteString ->
  RedisCommandClient client RespData ->
  ClusterCommandClient client (Either ClusterError RespData)
executeKeyedCommand key action = do
  ClusterClientState client connector <- State.get
  liftIO $ executeClusterCommand client key action connector

-- | Internal helper to execute a keyless command within ClusterCommandClient monad
executeKeylessCommand ::
  (Client client) =>
  RedisCommandClient client a ->
  ClusterCommandClient client (Either ClusterError a)
executeKeylessCommand action = do
  ClusterClientState client connector <- State.get
  liftIO $ executeKeylessClusterCommand client action connector

-- | Helper to unwrap Either ClusterError or fail
unwrapClusterResult :: (Client client) => Either ClusterError a -> ClusterCommandClient client a
unwrapClusterResult (Right a)  = pure a
unwrapClusterResult (Left err) = Prelude.fail $ "Cluster error: " ++ show err

-- | Execute a keyed command and unwrap the result
executeKeyed :: (Client client) => String -> RedisCommandClient client RespData -> ClusterCommandClient client RespData
executeKeyed key action = do
  result <- executeKeyedCommand (BS.pack key) action
  unwrapClusterResult result

-- | Execute a keyless command and unwrap the result
executeKeyless :: (Client client) => RedisCommandClient client a -> ClusterCommandClient client a
executeKeyless action = do
  result <- executeKeylessCommand action
  unwrapClusterResult result

instance (Client client) => RedisCommands (ClusterCommandClient client) where
  auth username password = executeKeyless (RedisCommandClient.auth username password)
  ping = executeKeyless RedisCommandClient.ping
  set k v = executeKeyed k (RedisCommandClient.set k v)
  get k = executeKeyed k (RedisCommandClient.get k)
  mget keys = case keys of
    []    -> executeKeyless (RedisCommandClient.mget [])
    (k:_) -> executeKeyed k (RedisCommandClient.mget keys)
  setnx k v = executeKeyed k (RedisCommandClient.setnx k v)
  decr k = executeKeyed k (RedisCommandClient.decr k)
  psetex k ms v = executeKeyed k (RedisCommandClient.psetex k ms v)
  bulkSet kvs = case kvs of
    []         -> executeKeyless (RedisCommandClient.bulkSet [])
    ((k, _):_) -> executeKeyed k (RedisCommandClient.bulkSet kvs)
  flushAll = executeKeyless RedisCommandClient.flushAll
  dbsize = executeKeyless RedisCommandClient.dbsize
  del keys = case keys of
    []    -> executeKeyless (RedisCommandClient.del [])
    (k:_) -> executeKeyed k (RedisCommandClient.del keys)
  exists keys = case keys of
    []    -> executeKeyless (RedisCommandClient.exists [])
    (k:_) -> executeKeyed k (RedisCommandClient.exists keys)
  incr k = executeKeyed k (RedisCommandClient.incr k)
  hset k f v = executeKeyed k (RedisCommandClient.hset k f v)
  hget k f = executeKeyed k (RedisCommandClient.hget k f)
  hmget k fs = executeKeyed k (RedisCommandClient.hmget k fs)
  hexists k f = executeKeyed k (RedisCommandClient.hexists k f)
  lpush k vs = executeKeyed k (RedisCommandClient.lpush k vs)
  lrange k start stop = executeKeyed k (RedisCommandClient.lrange k start stop)
  expire k secs = executeKeyed k (RedisCommandClient.expire k secs)
  ttl k = executeKeyed k (RedisCommandClient.ttl k)
  rpush k vs = executeKeyed k (RedisCommandClient.rpush k vs)
  lpop k = executeKeyed k (RedisCommandClient.lpop k)
  rpop k = executeKeyed k (RedisCommandClient.rpop k)
  sadd k vs = executeKeyed k (RedisCommandClient.sadd k vs)
  smembers k = executeKeyed k (RedisCommandClient.smembers k)
  scard k = executeKeyed k (RedisCommandClient.scard k)
  sismember k v = executeKeyed k (RedisCommandClient.sismember k v)
  hdel k fs = executeKeyed k (RedisCommandClient.hdel k fs)
  hkeys k = executeKeyed k (RedisCommandClient.hkeys k)
  hvals k = executeKeyed k (RedisCommandClient.hvals k)
  llen k = executeKeyed k (RedisCommandClient.llen k)
  lindex k idx = executeKeyed k (RedisCommandClient.lindex k idx)
  clientSetInfo args = executeKeyless (RedisCommandClient.clientSetInfo args)
  clientReply val = executeKeyless (RedisCommandClient.clientReply val)
  zadd k scores = executeKeyed k (RedisCommandClient.zadd k scores)
  zrange k start stop withScores = executeKeyed k (RedisCommandClient.zrange k start stop withScores)
  geoadd k members = executeKeyed k (RedisCommandClient.geoadd k members)
  geodist k m1 m2 unit = executeKeyed k (RedisCommandClient.geodist k m1 m2 unit)
  geohash k members = executeKeyed k (RedisCommandClient.geohash k members)
  geopos k members = executeKeyed k (RedisCommandClient.geopos k members)
  georadius k lon lat radius unit flags = executeKeyed k (RedisCommandClient.georadius k lon lat radius unit flags)
  georadiusRo k lon lat radius unit flags = executeKeyed k (RedisCommandClient.georadiusRo k lon lat radius unit flags)
  georadiusByMember k member radius unit flags = executeKeyed k (RedisCommandClient.georadiusByMember k member radius unit flags)
  georadiusByMemberRo k member radius unit flags = executeKeyed k (RedisCommandClient.georadiusByMemberRo k member radius unit flags)
  geosearch k from by opts = executeKeyed k (RedisCommandClient.geosearch k from by opts)
  geosearchstore dest src from by opts storeDist = executeKeyed dest (RedisCommandClient.geosearchstore dest src from by opts storeDist)
  clusterSlots = executeKeyless RedisCommandClient.clusterSlots
