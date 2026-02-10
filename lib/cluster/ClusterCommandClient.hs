{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

-- | Cluster-aware Redis command client with automatic slot routing, MOVED\/ASK
-- redirection handling, and connection pooling.
--
-- == Quick Start
--
-- @
-- -- Create a cluster client
-- client <- 'createClusterClient' config connector
--
-- -- One-shot convenience wrappers (recommended for simple operations):
-- 'clusterSet' client \"mykey\" \"myvalue\"
-- result <- 'clusterGet' client \"mykey\"
--
-- -- For commands without a convenience wrapper:
-- 'executeClusterCommand' client (pack \"mykey\") (lrange \"mykey\" 0 10)
--
-- -- Monadic style (for multi-command sequences):
-- 'runClusterCommandClient' client $ do
--   set \"key1\" \"val1\"
--   set \"key2\" \"val2\"
--   get \"key1\"
--
-- 'closeClusterClient' client
-- @
--
-- == Choosing an Execution Style
--
-- * __Convenience wrappers__ ('clusterGet', 'clusterSet', 'clusterDel', …):
--   Best for one-shot operations from @IO@. The key is specified once;
--   routing and command execution are handled together. Keys are 'String',
--   matching the 'RedisCommands' typeclass, so no manual packing is needed.
--
-- * __'executeClusterCommand'__: Low-level one-shot execution from @IO@.
--   Use when you need a command that doesn't have a convenience wrapper.
--   Requires the routing key as a 'ByteString' and the command as a
--   'RedisCommandClient' action.
--
-- * __'runClusterCommandClient'__: Monadic interface implementing 'RedisCommands'.
--   Best for multi-command sequences where you want the same familiar API as
--   single-node Redis. Note: each command still routes independently; there are
--   no multi-key transactions across slots.
module ClusterCommandClient
  ( -- * Client Types
    ClusterClient (..),
    ClusterCommandClient,
    ClusterError (..),
    ClusterConfig (..),
    -- * Client Lifecycle
    createClusterClient,
    closeClusterClient,
    refreshTopology,
    -- * Convenience Wrappers (one-shot, String keys)
    -- | These combine routing and command execution so you specify the key once.
    -- They accept 'String' keys (matching 'RedisCommands') and return
    -- @IO (Either 'ClusterError' 'RespData')@.
    clusterGet,
    clusterSet,
    clusterDel,
    clusterPsetex,
    clusterSetnx,
    clusterIncr,
    clusterDecr,
    clusterExpire,
    clusterTtl,
    clusterExists,
    clusterHset,
    clusterHget,
    clusterHdel,
    clusterLpush,
    clusterLrange,
    clusterSadd,
    clusterSmembers,
    -- Keyless convenience wrappers
    clusterPing,
    clusterFlushAll,
    clusterDbsize,
    -- * Low-Level Command Execution
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

import           Client                      (Client (..))
import           Cluster                     (ClusterNode (..),
                                              ClusterTopology (..),
                                              NodeAddress (..), NodeRole (..),
                                              calculateSlot, findNodeForSlot,
                                              parseClusterSlots)
import           Connector                   (Connector)
import           ConnectionPool              (ConnectionPool, PoolConfig (..),
                                              closePool, createPool,
                                              getOrCreateConnection,
                                              withConnection)
import           Control.Concurrent          (threadDelay)
import           Control.Concurrent.MVar     (MVar, newMVar, tryTakeMVar,
                                              putMVar)
import           Control.Concurrent.STM      (TVar, atomically,
                                              newTVarIO, readTVarIO, writeTVar)
import           Control.Exception           (SomeException, finally, throwIO,
                                              try)
import           Control.Monad               (when)
import           Control.Monad.IO.Class      (MonadIO (..))
import qualified Control.Monad.State         as State
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Char8       as BS
import qualified Data.Map.Strict             as Map
import           Data.Time.Clock             (NominalDiffTime, diffUTCTime, getCurrentTime)
import qualified Data.Text                   as T
import           Data.Word                   (Word16)
import           RedisCommandClient          (ClientState (..),
                                              RedisCommandClient (..),
                                              RedisCommands (..), parseWith,
                                              runRedisCommandClient)
import           Resp                        (RespData (..))

-- | Error types specific to cluster operations.
data ClusterError
  = MovedError Word16 NodeAddress -- ^ Permanent redirect: the slot has migrated to a different node.
  | AskError Word16 NodeAddress -- ^ Temporary redirect during slot migration; retry at the given node.
  | ClusterDownError String -- ^ The cluster is in a down or error state.
  | TryAgainError String -- ^ Transient failure; the operation should be retried.
  | CrossSlotError String -- ^ Multi-key command spans multiple hash slots.
  | MaxRetriesExceeded String -- ^ All retry attempts exhausted.
  | TopologyError String -- ^ Slot or node lookup failed (e.g., empty topology).
  | ConnectionError String -- ^ Network-level failure connecting to a node.
  deriving (Show, Eq)

-- | Redirection information parsed from errors
data RedirectionInfo = RedirectionInfo
  { redirSlot :: Word16,
    redirHost :: String,
    redirPort :: Int
  }
  deriving (Show, Eq)

-- | Configuration for a cluster client.
data ClusterConfig = ClusterConfig
  { clusterSeedNode                :: NodeAddress -- ^ Initial node used to discover the cluster topology.
  , clusterPoolConfig              :: PoolConfig  -- ^ Connection pool settings applied to every node.
  , clusterMaxRetries              :: Int -- ^ Maximum retry attempts on MOVED\/ASK\/transient errors (default: 3).
  , clusterRetryDelay              :: Int -- ^ Initial retry delay in microseconds; doubled on each retry (default: 100000 = 100ms).
  , clusterTopologyRefreshInterval :: Int -- ^ Seconds between automatic background topology refreshes (default: 600 = 10 min).
  }
  deriving (Show)

-- | A cluster client that manages topology discovery and a per-node connection pool.
-- Created via 'createClusterClient' and closed with 'closeClusterClient'.
data ClusterClient client = ClusterClient
  { clusterTopology       :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig         :: ClusterConfig,
    clusterConnector      :: Connector client,   -- ^ Connector factory used for all connections
    clusterRefreshLock    :: MVar ()  -- ^ Lock to prevent concurrent topology refreshes
  }

-- | Monad for executing Redis commands on a cluster
-- Wraps StateT to abstract away the client state
data ClusterCommandClient client a where
  ClusterCommandClient :: (Client client) =>
    State.StateT (ClusterClient client) IO a
    -> ClusterCommandClient client a

-- | Run a sequence of Redis commands against the cluster using the 'RedisCommands'
-- monad interface. Best for multi-command workflows where you want the familiar
-- @get@\/@set@\/@del@ API with transparent cluster routing.
--
-- Each command within the monad routes independently to the correct node.
-- There are no multi-key atomicity guarantees across slots.
--
-- For one-shot operations, prefer the convenience wrappers ('clusterGet',
-- 'clusterSet', etc.) or 'executeClusterCommand'.
runClusterCommandClient ::
  (Client client) =>
  ClusterClient client ->
  ClusterCommandClient client a ->
  IO a
runClusterCommandClient client (ClusterCommandClient action) =
  State.evalStateT action client

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

instance (Client client) => State.MonadState (ClusterClient client) (ClusterCommandClient client) where
  get :: ClusterCommandClient client (ClusterClient client)
  get = ClusterCommandClient State.get
  put :: ClusterClient client -> ClusterCommandClient client ()
  put = ClusterCommandClient . State.put

instance (Client client) => MonadFail (ClusterCommandClient client) where
  fail :: String -> ClusterCommandClient client a
  fail = ClusterCommandClient . liftIO . Prelude.fail

-- | Connect to the seed node, issue @CLUSTER SLOTS@, and build the initial topology.
-- Throws on failure to connect or parse the topology response.
createClusterClient ::
  (Client client) =>
  ClusterConfig ->
  Connector client ->
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
      refreshLock <- newMVar ()
      return $ ClusterClient topology pool config connector refreshLock

-- | Close all pooled connections across every node.
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = closePool (clusterConnectionPool client)

-- | Refresh cluster topology by querying CLUSTER SLOTS.
-- Uses a lock to prevent thundering herd: if another thread is already
-- refreshing, this call returns immediately (the other thread's refresh
-- will update the shared topology).
refreshTopology ::
  (Client client) =>
  ClusterClient client ->
  IO ()
refreshTopology client = do
  acquired <- tryTakeMVar (clusterRefreshLock client)
  case acquired of
    Nothing -> return ()  -- Another thread is already refreshing
    Just _  -> finally doRefresh (putMVar (clusterRefreshLock client) ())
  where
    connector = clusterConnector client
    doRefresh = do
      let seedNode = clusterSeedNode (clusterConfig client)
      conn <- getOrCreateConnection (clusterConnectionPool client) seedNode connector

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
  IO ()
refreshTopologyIfStale client = do
  topology <- readTVarIO (clusterTopology client)
  currentTime <- getCurrentTime
  let timeSinceUpdate = diffUTCTime currentTime (topologyUpdateTime topology)
      refreshInterval = fromIntegral (clusterTopologyRefreshInterval (clusterConfig client)) :: NominalDiffTime
  when (timeSinceUpdate >= refreshInterval) $ do
    refreshTopology client

-- | Detect MOVED or ASK errors from RespData
detectRedirection :: RespData -> Maybe (Either RedirectionInfo RedirectionInfo)
detectRedirection (RespError msg) =
  case parseRedirectionError "MOVED" msg of
       Just redir -> Just (Left redir)  -- Left for MOVED
       Nothing -> case parseRedirectionError "ASK" msg of
         Just redir -> Just (Right redir)  -- Right for ASK
         Nothing -> Nothing
detectRedirection _ = Nothing

-- | Low-level one-shot command execution with explicit routing key.
-- The @key@ ('ByteString') determines which cluster node receives the command.
-- Handles MOVED\/ASK redirection and retries automatically.
--
-- For most common operations, prefer the convenience wrappers ('clusterGet',
-- 'clusterSet', etc.) which accept 'String' keys and eliminate key duplication.
-- Use this function for commands not covered by a wrapper.
executeClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  ByteString -> -- The key to determine routing
  RedisCommandClient client RespData ->
  IO (Either ClusterError RespData)
executeClusterCommand client key action = do
  refreshTopologyIfStale client
  
  let connector = clusterConnector client
  slot <- calculateSlot key
  withRetryAndRefresh client (clusterMaxRetries (clusterConfig client)) (clusterRetryDelay (clusterConfig client)) $ do
    executeOnSlot client slot action connector

-- | Execute a command on the node responsible for a given slot
executeOnSlot ::
  (Client client) =>
  ClusterClient client ->
  Word16 ->
  RedisCommandClient client RespData ->
  Connector client ->
  IO (Either ClusterError RespData)
executeOnSlot client slot action connector = do
  topology <- readTVarIO (clusterTopology client)
  case findNodeForSlot topology slot of
    Nothing -> return $ Left $ TopologyError $ "No node found for slot " ++ show slot
    Just nodeId -> do
      case Map.lookup nodeId (topologyNodes topology) of
        Nothing -> return $ Left $ TopologyError $ "Node ID " ++ T.unpack nodeId ++ " not found in topology"
        Just node -> executeOnNodeWithRedirectionDetection client (nodeAddress node) action connector

-- | Execute a command on a specific node
executeOnNode ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client a ->
  Connector client ->
  IO (Either ClusterError a)
executeOnNode client nodeAddr action connector = do
  result <- try $ withConnection (clusterConnectionPool client) nodeAddr connector $ \conn -> do
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
  Connector client ->
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

-- | Execute a command that does not target a specific key (e.g., PING, AUTH, FLUSHALL).
-- Routed to an arbitrary master node.
executeKeylessClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  RedisCommandClient client a ->
  IO (Either ClusterError a)
executeKeylessClusterCommand client action = do
  let connector = clusterConnector client
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  case masterNodes of
    []       -> return $ Left $ TopologyError "No master nodes available"
    (node:_) -> executeOnNode client (nodeAddress node) action connector

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
  Int -> -- Max retries
  Int -> -- Initial delay (microseconds)
  IO (Either ClusterError a) ->
  IO (Either ClusterError a)
withRetryAndRefresh client maxRetries initialDelay action = go 0 initialDelay
  where
    go attempt delay
      | attempt >= maxRetries = return $ Left $ MaxRetriesExceeded $ "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action
          case result of
            Left (TryAgainError _) -> do
              threadDelay delay
              go (attempt + 1) (delay * 2)
            Left (MovedError _ _) -> do
              refreshTopology client
              go (attempt + 1) delay
            Left (AskError _ _) -> do
              threadDelay delay
              go (attempt + 1) delay
            Left (ConnectionError _) -> do
              refreshTopology client
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
          case (reads slotStr :: [(Integer, String)]) of
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
  client <- State.get
  liftIO $ executeClusterCommand client key action

-- | Internal helper to execute a keyless command within ClusterCommandClient monad
executeKeylessCommand ::
  (Client client) =>
  RedisCommandClient client a ->
  ClusterCommandClient client (Either ClusterError a)
executeKeylessCommand action = do
  client <- State.get
  liftIO $ executeKeylessClusterCommand client action

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

-- ---------------------------------------------------------------------------
-- Convenience wrappers: one-shot IO functions with String keys
-- ---------------------------------------------------------------------------
-- These eliminate the double-key problem by combining routing and command
-- execution. Use these for simple one-shot operations from IO.

-- | @clusterGet client key@ — retrieve the value of @key@.
clusterGet :: (Client client) => ClusterClient client -> String -> IO (Either ClusterError RespData)
clusterGet client key = executeClusterCommand client (BS.pack key) (RedisCommandClient.get key)

-- | @clusterSet client key value@ — set @key@ to @value@.
clusterSet :: (Client client) => ClusterClient client -> String -> String -> IO (Either ClusterError RespData)
clusterSet client key val = executeClusterCommand client (BS.pack key) (RedisCommandClient.set key val)

-- | @clusterDel client keys@ — delete one or more keys. Routed by the first key.
clusterDel :: (Client client) => ClusterClient client -> [String] -> IO (Either ClusterError RespData)
clusterDel client keys = case keys of
  []    -> pure (Right (RespInteger 0))
  (k:_) -> executeClusterCommand client (BS.pack k) (RedisCommandClient.del keys)

-- | @clusterPsetex client key milliseconds value@ — set @key@ with a TTL in milliseconds.
clusterPsetex :: (Client client) => ClusterClient client -> String -> Int -> String -> IO (Either ClusterError RespData)
clusterPsetex client key ms val = executeClusterCommand client (BS.pack key) (RedisCommandClient.psetex key ms val)

-- | @clusterSetnx client key value@ — set @key@ only if it does not already exist.
clusterSetnx :: (Client client) => ClusterClient client -> String -> String -> IO (Either ClusterError RespData)
clusterSetnx client key val = executeClusterCommand client (BS.pack key) (RedisCommandClient.setnx key val)

-- | @clusterIncr client key@ — increment the integer value of @key@ by 1.
clusterIncr :: (Client client) => ClusterClient client -> String -> IO (Either ClusterError RespData)
clusterIncr client key = executeClusterCommand client (BS.pack key) (RedisCommandClient.incr key)

-- | @clusterDecr client key@ — decrement the integer value of @key@ by 1.
clusterDecr :: (Client client) => ClusterClient client -> String -> IO (Either ClusterError RespData)
clusterDecr client key = executeClusterCommand client (BS.pack key) (RedisCommandClient.decr key)

-- | @clusterExpire client key seconds@ — set a timeout on @key@.
clusterExpire :: (Client client) => ClusterClient client -> String -> Int -> IO (Either ClusterError RespData)
clusterExpire client key secs = executeClusterCommand client (BS.pack key) (RedisCommandClient.expire key secs)

-- | @clusterTtl client key@ — get the remaining time to live of @key@ in seconds.
clusterTtl :: (Client client) => ClusterClient client -> String -> IO (Either ClusterError RespData)
clusterTtl client key = executeClusterCommand client (BS.pack key) (RedisCommandClient.ttl key)

-- | @clusterExists client keys@ — check if one or more keys exist. Routed by the first key.
clusterExists :: (Client client) => ClusterClient client -> [String] -> IO (Either ClusterError RespData)
clusterExists client keys = case keys of
  []    -> pure (Right (RespInteger 0))
  (k:_) -> executeClusterCommand client (BS.pack k) (RedisCommandClient.exists keys)

-- | @clusterHset client key field value@ — set a hash field.
clusterHset :: (Client client) => ClusterClient client -> String -> String -> String -> IO (Either ClusterError RespData)
clusterHset client key field val = executeClusterCommand client (BS.pack key) (RedisCommandClient.hset key field val)

-- | @clusterHget client key field@ — get a hash field value.
clusterHget :: (Client client) => ClusterClient client -> String -> String -> IO (Either ClusterError RespData)
clusterHget client key field = executeClusterCommand client (BS.pack key) (RedisCommandClient.hget key field)

-- | @clusterHdel client key fields@ — delete one or more hash fields.
clusterHdel :: (Client client) => ClusterClient client -> String -> [String] -> IO (Either ClusterError RespData)
clusterHdel client key fields = executeClusterCommand client (BS.pack key) (RedisCommandClient.hdel key fields)

-- | @clusterLpush client key values@ — prepend values to a list.
clusterLpush :: (Client client) => ClusterClient client -> String -> [String] -> IO (Either ClusterError RespData)
clusterLpush client key vals = executeClusterCommand client (BS.pack key) (RedisCommandClient.lpush key vals)

-- | @clusterLrange client key start stop@ — get a range of elements from a list.
clusterLrange :: (Client client) => ClusterClient client -> String -> Int -> Int -> IO (Either ClusterError RespData)
clusterLrange client key start stop = executeClusterCommand client (BS.pack key) (RedisCommandClient.lrange key start stop)

-- | @clusterSadd client key members@ — add members to a set.
clusterSadd :: (Client client) => ClusterClient client -> String -> [String] -> IO (Either ClusterError RespData)
clusterSadd client key members = executeClusterCommand client (BS.pack key) (RedisCommandClient.sadd key members)

-- | @clusterSmembers client key@ — get all members of a set.
clusterSmembers :: (Client client) => ClusterClient client -> String -> IO (Either ClusterError RespData)
clusterSmembers client key = executeClusterCommand client (BS.pack key) (RedisCommandClient.smembers key)

-- | @clusterPing client@ — ping any master node.
clusterPing :: (Client client) => ClusterClient client -> IO (Either ClusterError RespData)
clusterPing client = executeKeylessClusterCommand client RedisCommandClient.ping

-- | @clusterFlushAll client@ — flush all keys on one master.
-- Note: in a cluster, this only affects the targeted node.
clusterFlushAll :: (Client client) => ClusterClient client -> IO (Either ClusterError RespData)
clusterFlushAll client = executeKeylessClusterCommand client RedisCommandClient.flushAll

-- | @clusterDbsize client@ — get the number of keys on one master.
clusterDbsize :: (Client client) => ClusterClient client -> IO (Either ClusterError RespData)
clusterDbsize client = executeKeylessClusterCommand client RedisCommandClient.dbsize
