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
-- import Redis
--
-- client <- 'createClusterClient' config connector
--
-- -- Use the monadic interface (implements 'RedisCommands'):
-- 'runClusterCommandClient' client $ do
--   set \"key1\" \"val1\"
--   set \"key2\" \"val2\"
--   get \"key1\"
--
-- -- One-shot from IO:
-- result <- 'runClusterCommandClient' client (get \"mykey\")
--
-- 'closeClusterClient' client
-- @
--
-- The 'ClusterCommandClient' monad implements 'RedisCommands', providing
-- the same @get@\/@set@\/@del@\/… API as single-node Redis with transparent
-- cluster slot routing, MOVED\/ASK handling, and connection pooling.
--
-- For advanced use (e.g.\ forwarding raw RESP commands), the low-level
-- 'executeKeyedClusterCommand' and 'executeKeylessClusterCommand' are also
-- available but are not re-exported by the convenience "Redis" module.
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
    -- * Running Commands (monadic, recommended)
    runClusterCommandClient,
    -- * Low-Level Command Execution (advanced)
    -- | These are intended for internal use or advanced scenarios like RESP
    -- proxying. Prefer 'runClusterCommandClient' with 'RedisCommands' for
    -- normal Redis operations.
    executeKeyedClusterCommand,
    executeKeylessClusterCommand,
    -- * Re-export RedisCommands for convenience
    module RedisCommandClient,
    -- * Internal (exported for testing)
    RedirectionInfo (..),
    parseRedirectionError,
    detectRedirection,
  )
where

import           Cluster                 (ClusterNode (..),
                                          ClusterTopology (..),
                                          NodeAddress (..), NodeRole (..),
                                          calculateSlot, findNodeAddressForSlot,
                                          parseClusterSlots)
import           ConnectionPool          (ConnectionPool, PoolConfig (..),
                                          closePool, createPool, withConnection)
import           Connector               (Connector)
import           Control.Concurrent      (threadDelay)
import           Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar)
import           Control.Concurrent.STM  (TVar, atomically, newTVarIO,
                                          readTVarIO, writeTVar)
import           Control.Exception       (SomeException, finally, throwIO, try)
import           Control.Monad           (when)
import           Control.Monad.IO.Class  (MonadIO (..))
import qualified Control.Monad.State     as State
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8   as BS8
import qualified Data.Map.Strict         as Map
import           Data.Time.Clock         (NominalDiffTime, diffUTCTime,
                                          getCurrentTime)
import           Data.Word               (Word16)
import           Database.Redis.Client   (Client (..))
import           Database.Redis.Resp     (RespData (..))
import           FromResp                (FromResp (..))
import           MultiplexPool           (MultiplexPool, closeMultiplexPool,
                                          createMultiplexPool, submitToNode,
                                          submitToNodeWithAsking)
import           RedisCommandClient      (ClientState (..),
                                          RedisCommandClient (..),
                                          RedisCommands (..), convertResp,
                                          encodeCommandBuilder,
                                          geoRadiusFlagToList,
                                          geoSearchByToList,
                                          geoSearchFromToList,
                                          geoSearchOptionToList, geoUnitKeyword,
                                          runRedisCommandClient, showBS)

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

-- | A cluster client that manages topology discovery, a per-node connection pool
-- (for keyless commands and topology refresh), and a multiplexer pool for
-- pipelined keyed command execution.
-- Created via 'createClusterClient' and closed with 'closeClusterClient'.
data ClusterClient client = ClusterClient
  { clusterTopology       :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig         :: ClusterConfig,
    clusterConnector      :: Connector client,   -- ^ Connector factory used for all connections
    clusterRefreshLock    :: MVar ()  -- ^ Lock to prevent concurrent topology refreshes
  , clusterMultiplexPool  :: MultiplexPool client -- ^ Multiplexer pool for pipelined command execution
  }

-- | Monad for executing Redis commands on a cluster
-- Wraps StateT to abstract away the client state
data ClusterCommandClient client a where
  ClusterCommandClient :: (Client client) =>
    State.StateT (ClusterClient client) IO a
    -> ClusterCommandClient client a

-- | Run Redis commands against the cluster. This is the primary API.
--
-- The 'ClusterCommandClient' monad implements 'RedisCommands', so you can use
-- the familiar @get@\/@set@\/@del@\/… functions with transparent cluster routing.
-- Each command routes independently to the correct node. Works for both
-- single commands and multi-command sequences.
--
-- @
-- -- Single command:
-- result <- runClusterCommandClient client (get \"mykey\")
--
-- -- Multi-command sequence:
-- runClusterCommandClient client $ do
--   set \"key1\" \"val1\"
--   set \"key2\" \"val2\"
--   get \"key1\"
-- @
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
  response <- withConnection pool seedNode connector $ \conn -> do
    let clientState = ClientState conn BS8.empty
    State.evalStateT (runRedisCommandClient clusterSlots) clientState

  currentTime <- getCurrentTime
  case parseClusterSlots response currentTime of
    Left err -> throwIO $ userError $ "Failed to parse cluster topology: " <> err
    Right initialTopology -> do
      topology <- newTVarIO initialTopology
      refreshLock <- newMVar ()
      muxPool <- createMultiplexPool connector 1
      return $ ClusterClient topology pool config connector refreshLock muxPool

-- | Close all pooled connections across every node.
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = do
  closePool (clusterConnectionPool client)
  closeMultiplexPool (clusterMultiplexPool client)

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
      response <- withConnection (clusterConnectionPool client) seedNode connector $ \conn -> do
        let clientState = ClientState conn BS8.empty
        State.evalStateT (runRedisCommandClient clusterSlots) clientState

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

-- | Detect MOVED or ASK errors from RespData.
-- Common case (no redirect) is a constructor check plus at most a single byte
-- comparison, with zero allocation.
{-# INLINE detectRedirection #-}
detectRedirection :: RespData -> Maybe (Either RedirectionInfo RedirectionInfo)
detectRedirection (RespError msg)
  | BS.length msg >= 6  -- shortest redirect: "ASK x y" needs >= 7 chars
  , let w = BS.index msg 0
  = if w == 0x4D  -- 'M'
    then if BS.isPrefixOf "MOVED " msg
         then case parseMovedAsk (BS.drop 6 msg) of
                Just redir -> Just (Left redir)
                Nothing    -> Nothing
         else Nothing
    else if w == 0x41  -- 'A'
    then if BS.isPrefixOf "ASK " msg
         then case parseMovedAsk (BS.drop 4 msg) of
                Just redir -> Just (Right redir)
                Nothing    -> Nothing
         else Nothing
    else Nothing
  | otherwise = Nothing
detectRedirection _ = Nothing

-- | Execute a command on a specific node (used for keyless commands and topology refresh)
executeOnNode ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client a ->
  Connector client ->
  IO (Either ClusterError a)
executeOnNode client nodeAddr action connector = do
  result <- try $ withConnection (clusterConnectionPool client) nodeAddr connector $ \conn -> do
    let clientState = ClientState conn BS8.empty
    State.evalStateT (runRedisCommandClient action) clientState

  case result of
    Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
    Right value               -> return $ Right value

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
-- ASK errors follow the Redis protocol: retry at the target node with an ASKING prefix.
-- No topology refresh is needed since ASK indicates a temporary, in-progress migration.
withRetryAndRefresh ::
  (Client client) =>
  ClusterClient client ->
  Int -> -- Max retries
  Int -> -- Initial delay (microseconds)
  (Maybe NodeAddress -> IO (Either ClusterError a)) ->
  IO (Either ClusterError a)
withRetryAndRefresh client maxRetries initialDelay action = go 0 initialDelay Nothing
  where
    go attempt delay askTarget
      | attempt >= maxRetries = return $ Left $ MaxRetriesExceeded $ "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action askTarget
          case result of
            Left (TryAgainError _) -> do
              threadDelay delay
              go (attempt + 1) (delay * 2) Nothing
            Left (MovedError _ _) -> do
              refreshTopology client
              go (attempt + 1) delay Nothing
            Left (AskError _ addr) -> do
              go (attempt + 1) delay (Just addr)
            Left (ConnectionError _) -> do
              refreshTopology client
              go (attempt + 1) delay Nothing
            Left err -> return $ Left err
            Right value -> return $ Right value

-- | Parse the payload after "MOVED " or "ASK " prefix.
-- Input format: "3999 127.0.0.1:6381" (slot, space, host:port)
-- Avoids BS8.words allocation by using break/drop directly.
{-# INLINE parseMovedAsk #-}
parseMovedAsk :: ByteString -> Maybe RedirectionInfo
parseMovedAsk rest =
  case BS8.readInt rest of
    Just (slot, afterSlot)
      | not (BS8.null afterSlot)
      , BS8.head afterSlot == ' '
      -> let hostPort = BS8.tail afterSlot
         in case BS8.break (== ':') hostPort of
              (host, portPart)
                | not (BS8.null portPart)
                -> case BS8.readInt (BS8.tail portPart) of
                     Just (port, rest')
                       | BS8.null rest'
                       -> Just $ RedirectionInfo (fromIntegral slot) (BS8.unpack host) port
                     _ -> Nothing
              _ -> Nothing
    _ -> Nothing

-- | Parse redirection error messages (backward-compatible wrapper).
-- Format: "MOVED 3999 127.0.0.1:6381" or "ASK 3999 127.0.0.1:6381"
parseRedirectionError :: ByteString -> ByteString -> Maybe RedirectionInfo
parseRedirectionError errorType msg
  | BS.isPrefixOf errorType msg
  , BS.length msg > BS.length errorType
  , BS.index msg (BS.length errorType) == 0x20  -- ' '
  = parseMovedAsk (BS.drop (BS.length errorType + 1) msg)
  | otherwise = Nothing

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

-- | Execute a keyed command and unwrap the result.
-- Routes through the multiplexer pool for pipelined execution.
executeKeyed :: (Client client) => ByteString -> [ByteString] -> ClusterCommandClient client RespData
executeKeyed key cmdArgs = do
  client <- State.get
  result <- liftIO $ executeKeyedClusterCommand client key cmdArgs
  unwrapClusterResult result

-- | Execute a keyed command, unwrap, and convert via 'FromResp'.
executeKeyedAs :: (Client client, FromResp a) => ByteString -> [ByteString] -> ClusterCommandClient client a
executeKeyedAs key cmdArgs = executeKeyed key cmdArgs >>= convertResp

-- | Execute a keyless command and unwrap the result
executeKeyless :: (Client client) => RedisCommandClient client a -> ClusterCommandClient client a
executeKeyless action = do
  result <- executeKeylessCommand action
  unwrapClusterResult result

-- | Execute a keyed command via the multiplexer pool.
-- Pre-encodes the command to a Builder, routes by slot, and handles MOVED/ASK redirection.
--
-- This is the low-level API for executing commands with explicit routing key.
-- For most operations, prefer 'runClusterCommandClient' with 'RedisCommands'.
executeKeyedClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  ByteString ->           -- key for routing
  [ByteString] ->         -- command args
  IO (Either ClusterError RespData)
executeKeyedClusterCommand client key cmdArgs = do
  refreshTopologyIfStale client
  let muxPool = clusterMultiplexPool client
      cmdBuilder = encodeCommandBuilder cmdArgs
      !slot = calculateSlot key
  withRetryAndRefresh client (clusterMaxRetries (clusterConfig client)) (clusterRetryDelay (clusterConfig client)) $ \askTarget ->
    case askTarget of
      Nothing   -> executeOnSlotMux client muxPool slot cmdBuilder
      Just addr -> executeOnNodeWithAsking client muxPool addr cmdBuilder

-- | Execute a pre-encoded command via multiplexer on the node for a given slot.
-- Uses findNodeAddressForSlot for O(1) direct address lookup (no Map needed).
executeOnSlotMux ::
  (Client client) =>
  ClusterClient client ->
  MultiplexPool client ->
  Word16 ->
  Builder.Builder ->
  IO (Either ClusterError RespData)
executeOnSlotMux client muxPool slot cmdBuilder = do
  topology <- readTVarIO (clusterTopology client)
  case findNodeAddressForSlot topology slot of
    Nothing -> return $ Left $ TopologyError $ "No node found for slot " ++ show slot
    Just addr -> do
      result <- try $ submitToNode muxPool addr cmdBuilder
      case result of
        Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
        Right respData -> case detectRedirection respData of
          Just (Left (RedirectionInfo s host port)) ->
            return $ Left $ MovedError s (NodeAddress host port)
          Just (Right (RedirectionInfo s host port)) ->
            return $ Left $ AskError s (NodeAddress host port)
          Nothing -> return $ Right respData

-- | Execute a command on a specific node with ASKING prefix (for ASK redirects).
-- Per Redis protocol, ASK requires sending ASKING before the actual command to the
-- target node. Both commands are submitted atomically so no other command can be
-- interleaved between them on the multiplexed connection.
executeOnNodeWithAsking ::
  (Client client) =>
  ClusterClient client ->
  MultiplexPool client ->
  NodeAddress ->
  Builder.Builder ->
  IO (Either ClusterError RespData)
executeOnNodeWithAsking _client muxPool addr cmdBuilder = do
  let askingBuilder = encodeCommandBuilder ["ASKING"]
  result <- try $ submitToNodeWithAsking muxPool addr askingBuilder cmdBuilder
  case result of
    Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
    Right respData -> case detectRedirection respData of
      Just (Left (RedirectionInfo s host port)) ->
        return $ Left $ MovedError s (NodeAddress host port)
      Just (Right (RedirectionInfo s host port)) ->
        return $ Left $ AskError s (NodeAddress host port)
      Nothing -> return $ Right respData

instance (Client client) => RedisCommands (ClusterCommandClient client) where
  auth username password = executeKeyless (RedisCommandClient.auth username password)
  ping = executeKeyless RedisCommandClient.ping
  set k v = executeKeyedAs k ["SET", k, v]
  get k = executeKeyedAs k ["GET", k]
  mget keys = case keys of
    []    -> executeKeyless (RedisCommandClient.mget [])
    (k:_) -> executeKeyedAs k ("MGET" : keys)
  setnx k v = executeKeyedAs k ["SETNX", k, v]
  decr k = executeKeyedAs k ["DECR", k]
  psetex k ms v = executeKeyedAs k ["PSETEX", k, showBS ms, v]
  bulkSet kvs = case kvs of
    []         -> executeKeyless (RedisCommandClient.bulkSet [])
    ((k, _):_) -> executeKeyedAs k (["MSET"] <> concatMap (\(k', v') -> [k', v']) kvs)
  flushAll = executeKeyless RedisCommandClient.flushAll
  dbsize = executeKeyless RedisCommandClient.dbsize
  del keys = case keys of
    []    -> executeKeyless (RedisCommandClient.del [])
    (k:_) -> executeKeyedAs k ("DEL" : keys)
  exists keys = case keys of
    []    -> executeKeyless (RedisCommandClient.exists [])
    (k:_) -> executeKeyedAs k ("EXISTS" : keys)
  incr k = executeKeyedAs k ["INCR", k]
  hset k f v = executeKeyedAs k ["HSET", k, f, v]
  hget k f = executeKeyedAs k ["HGET", k, f]
  hmget k fs = executeKeyedAs k ("HMGET" : k : fs)
  hexists k f = executeKeyedAs k ["HEXISTS", k, f]
  lpush k vs = executeKeyedAs k ("LPUSH" : k : vs)
  lrange k start stop = executeKeyedAs k ["LRANGE", k, showBS start, showBS stop]
  expire k secs = executeKeyedAs k ["EXPIRE", k, showBS secs]
  ttl k = executeKeyedAs k ["TTL", k]
  rpush k vs = executeKeyedAs k ("RPUSH" : k : vs)
  lpop k = executeKeyedAs k ["LPOP", k]
  rpop k = executeKeyedAs k ["RPOP", k]
  sadd k vs = executeKeyedAs k ("SADD" : k : vs)
  smembers k = executeKeyedAs k ["SMEMBERS", k]
  scard k = executeKeyedAs k ["SCARD", k]
  sismember k v = executeKeyedAs k ["SISMEMBER", k, v]
  hdel k fs = executeKeyedAs k ("HDEL" : k : fs)
  hkeys k = executeKeyedAs k ["HKEYS", k]
  hvals k = executeKeyedAs k ["HVALS", k]
  llen k = executeKeyedAs k ["LLEN", k]
  lindex k idx = executeKeyedAs k ["LINDEX", k, showBS idx]
  clientSetInfo args = executeKeyless (RedisCommandClient.clientSetInfo args)
  clientReply val = executeKeyless (RedisCommandClient.clientReply val)
  zadd k members =
    let payload = concatMap (\(score, member) -> [showBS score, member]) members
    in executeKeyedAs k ("ZADD" : k : payload)
  zrange k start stop withScores =
    let base = ["ZRANGE", k, showBS start, showBS stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in executeKeyedAs k command
  geoadd k entries =
    let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
    in executeKeyedAs k ("GEOADD" : k : payload)
  geodist k m1 m2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in executeKeyedAs k (["GEODIST", k, m1, m2] ++ unitPart)
  geohash k members = executeKeyedAs k ("GEOHASH" : k : members)
  geopos k members = executeKeyedAs k ("GEOPOS" : k : members)
  georadius k lon lat radius unit flags =
    let base = ["GEORADIUS", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in executeKeyedAs k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusRo k lon lat radius unit flags =
    let base = ["GEORADIUS_RO", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in executeKeyedAs k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusByMember k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", k, member, showBS radius, geoUnitKeyword unit]
    in executeKeyedAs k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusByMemberRo k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", k, member, showBS radius, geoUnitKeyword unit]
    in executeKeyedAs k (base ++ concatMap geoRadiusFlagToList flags)
  geosearch k fromSpec bySpec options =
    executeKeyedAs k (["GEOSEARCH", k]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)
  geosearchstore dest src fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, src]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in executeKeyedAs dest command
  clusterSlots = executeKeyless RedisCommandClient.clusterSlots
