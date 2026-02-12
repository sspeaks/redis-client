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
-- 'executeClusterCommand' and 'executeKeylessClusterCommand' are also
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
                                              findNodeAddressForSlot,
                                              parseClusterSlots)
import           Connector                   (Connector)
import           ConnectionPool              (ConnectionPool, PoolConfig (..),
                                              closePool, createPool,
                                              withConnection)
import           MultiplexPool               (MultiplexPool,
                                              createMultiplexPool, submitToNode,
                                              closeMultiplexPool)
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
import qualified Data.ByteString.Builder     as Builder
import qualified Data.ByteString.Char8       as BS8
import qualified Data.Map.Strict             as Map
import           Data.Time.Clock             (NominalDiffTime, diffUTCTime, getCurrentTime)
import           Data.Word                   (Word16)
import           RedisCommandClient          (ClientState (..),
                                              RedisCommandClient (..),
                                              RedisCommands (..), encodeCommand,
                                              encodeCommandBuilder,
                                              parseWith, runRedisCommandClient,
                                              showBS, wrapInRay,
                                              geoUnitKeyword, geoRadiusFlagToList,
                                              geoSearchFromToList, geoSearchByToList,
                                              geoSearchOptionToList)
import           Resp                        (Encodable (..), RespData (..))

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
  , clusterUseMultiplexing         :: Bool -- ^ Enable multiplexed pipelining (default: False). When True, commands share a single multiplexed connection per node via batched writes and response demultiplexing.
  }
  deriving (Show)

-- | A cluster client that manages topology discovery and a per-node connection pool.
-- Created via 'createClusterClient' and closed with 'closeClusterClient'.
-- When multiplexing is enabled, also holds a 'MultiplexPool' for pipelined command execution.
data ClusterClient client = ClusterClient
  { clusterTopology       :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig         :: ClusterConfig,
    clusterConnector      :: Connector client,   -- ^ Connector factory used for all connections
    clusterRefreshLock    :: MVar ()  -- ^ Lock to prevent concurrent topology refreshes
  , clusterMultiplexPool  :: Maybe (MultiplexPool client) -- ^ Multiplexer pool (when multiplexing is enabled)
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
      muxPool <- if clusterUseMultiplexing config
        then Just <$> createMultiplexPool connector 1
        else return Nothing
      return $ ClusterClient topology pool config connector refreshLock muxPool

-- | Close all pooled connections across every node.
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = do
  closePool (clusterConnectionPool client)
  case clusterMultiplexPool client of
    Just muxPool -> closeMultiplexPool muxPool
    Nothing      -> return ()

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
      !slot = calculateSlot key
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
        Nothing -> return $ Left $ TopologyError $ "Node ID " ++ BS8.unpack nodeId ++ " not found in topology"
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
    let clientState = ClientState conn BS8.empty
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
parseRedirectionError :: ByteString -> ByteString -> Maybe RedirectionInfo
parseRedirectionError errorType msg =
  case BS8.words msg of
    (prefix : slotStr : hostPort : _)
      | prefix == errorType ->
          case BS8.readInt slotStr of
            Just (slot, rest) | BS8.null rest ->
              case BS8.break (== ':') hostPort of
                (host, portPart) | not (BS8.null portPart) ->
                  case BS8.readInt (BS8.tail portPart) of
                    Just (port, rest') | BS8.null rest' ->
                      Just $ RedirectionInfo (fromIntegral slot) (BS8.unpack host) port
                    _ -> Nothing
                _ -> Nothing
            _ -> Nothing
    _ -> Nothing

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
-- When multiplexing is enabled, uses the multiplexer pool for pipelined execution.
-- Falls back to the connection pool path otherwise.
executeKeyed :: (Client client) => ByteString -> [ByteString] -> ClusterCommandClient client RespData
executeKeyed key cmdArgs = do
  client <- State.get
  result <- liftIO $ case clusterMultiplexPool client of
    Just muxPool -> executeClusterCommandMux client muxPool key cmdArgs
    Nothing      -> executeClusterCommand client key (executeCommandFromArgs cmdArgs)
  unwrapClusterResult result

-- | Execute a keyless command and unwrap the result
executeKeyless :: (Client client) => RedisCommandClient client a -> ClusterCommandClient client a
executeKeyless action = do
  result <- executeKeylessCommand action
  unwrapClusterResult result

-- | Build a RedisCommandClient action from raw command args.
executeCommandFromArgs :: (Client client) => [ByteString] -> RedisCommandClient client RespData
executeCommandFromArgs args = do
  ClientState !conn _ <- State.get
  liftIO $ send conn (Builder.toLazyByteString $ encode $ wrapInRay args)
  parseWith (receive conn)

-- | Execute a keyed command via the multiplexer pool.
-- Pre-encodes the command to a Builder, routes by slot, and handles MOVED/ASK redirection.
executeClusterCommandMux ::
  (Client client) =>
  ClusterClient client ->
  MultiplexPool client ->
  ByteString ->           -- key for routing
  [ByteString] ->         -- command args
  IO (Either ClusterError RespData)
executeClusterCommandMux client muxPool key cmdArgs = do
  refreshTopologyIfStale client
  let cmdBuilder = encodeCommandBuilder cmdArgs
      !slot = calculateSlot key
  withRetryAndRefresh client (clusterMaxRetries (clusterConfig client)) (clusterRetryDelay (clusterConfig client)) $ do
    executeOnSlotMux client muxPool slot cmdBuilder

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

instance (Client client) => RedisCommands (ClusterCommandClient client) where
  auth username password = executeKeyless (RedisCommandClient.auth username password)
  ping = executeKeyless RedisCommandClient.ping
  set k v = executeKeyed k ["SET", k, v]
  get k = executeKeyed k ["GET", k]
  mget keys = case keys of
    []    -> executeKeyless (RedisCommandClient.mget [])
    (k:_) -> executeKeyed k ("MGET" : keys)
  setnx k v = executeKeyed k ["SETNX", k, v]
  decr k = executeKeyed k ["DECR", k]
  psetex k ms v = executeKeyed k ["PSETEX", k, showBS ms, v]
  bulkSet kvs = case kvs of
    []         -> executeKeyless (RedisCommandClient.bulkSet [])
    ((k, _):_) -> executeKeyed k (["MSET"] <> concatMap (\(k', v') -> [k', v']) kvs)
  flushAll = executeKeyless RedisCommandClient.flushAll
  dbsize = executeKeyless RedisCommandClient.dbsize
  del keys = case keys of
    []    -> executeKeyless (RedisCommandClient.del [])
    (k:_) -> executeKeyed k ("DEL" : keys)
  exists keys = case keys of
    []    -> executeKeyless (RedisCommandClient.exists [])
    (k:_) -> executeKeyed k ("EXISTS" : keys)
  incr k = executeKeyed k ["INCR", k]
  hset k f v = executeKeyed k ["HSET", k, f, v]
  hget k f = executeKeyed k ["HGET", k, f]
  hmget k fs = executeKeyed k ("HMGET" : k : fs)
  hexists k f = executeKeyed k ["HEXISTS", k, f]
  lpush k vs = executeKeyed k ("LPUSH" : k : vs)
  lrange k start stop = executeKeyed k ["LRANGE", k, showBS start, showBS stop]
  expire k secs = executeKeyed k ["EXPIRE", k, showBS secs]
  ttl k = executeKeyed k ["TTL", k]
  rpush k vs = executeKeyed k ("RPUSH" : k : vs)
  lpop k = executeKeyed k ["LPOP", k]
  rpop k = executeKeyed k ["RPOP", k]
  sadd k vs = executeKeyed k ("SADD" : k : vs)
  smembers k = executeKeyed k ["SMEMBERS", k]
  scard k = executeKeyed k ["SCARD", k]
  sismember k v = executeKeyed k ["SISMEMBER", k, v]
  hdel k fs = executeKeyed k ("HDEL" : k : fs)
  hkeys k = executeKeyed k ["HKEYS", k]
  hvals k = executeKeyed k ["HVALS", k]
  llen k = executeKeyed k ["LLEN", k]
  lindex k idx = executeKeyed k ["LINDEX", k, showBS idx]
  clientSetInfo args = executeKeyless (RedisCommandClient.clientSetInfo args)
  clientReply val = executeKeyless (RedisCommandClient.clientReply val)
  zadd k members =
    let payload = concatMap (\(score, member) -> [showBS score, member]) members
    in executeKeyed k ("ZADD" : k : payload)
  zrange k start stop withScores =
    let base = ["ZRANGE", k, showBS start, showBS stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    in executeKeyed k command
  geoadd k entries =
    let payload = concatMap (\(lon, lat, member) -> [showBS lon, showBS lat, member]) entries
    in executeKeyed k ("GEOADD" : k : payload)
  geodist k m1 m2 unit =
    let unitPart = maybe [] (\u -> [geoUnitKeyword u]) unit
    in executeKeyed k (["GEODIST", k, m1, m2] ++ unitPart)
  geohash k members = executeKeyed k ("GEOHASH" : k : members)
  geopos k members = executeKeyed k ("GEOPOS" : k : members)
  georadius k lon lat radius unit flags =
    let base = ["GEORADIUS", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in executeKeyed k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusRo k lon lat radius unit flags =
    let base = ["GEORADIUS_RO", k, showBS lon, showBS lat, showBS radius, geoUnitKeyword unit]
    in executeKeyed k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusByMember k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER", k, member, showBS radius, geoUnitKeyword unit]
    in executeKeyed k (base ++ concatMap geoRadiusFlagToList flags)
  georadiusByMemberRo k member radius unit flags =
    let base = ["GEORADIUSBYMEMBER_RO", k, member, showBS radius, geoUnitKeyword unit]
    in executeKeyed k (base ++ concatMap geoRadiusFlagToList flags)
  geosearch k fromSpec bySpec options =
    executeKeyed k (["GEOSEARCH", k]
      ++ geoSearchFromToList fromSpec
      ++ geoSearchByToList bySpec
      ++ concatMap geoSearchOptionToList options)
  geosearchstore dest src fromSpec bySpec options storeDist =
    let base = ["GEOSEARCHSTORE", dest, src]
            ++ geoSearchFromToList fromSpec
            ++ geoSearchByToList bySpec
            ++ concatMap geoSearchOptionToList options
        command = if storeDist then base ++ ["STOREDIST"] else base
    in executeKeyed dest command
  clusterSlots = executeKeyless RedisCommandClient.clusterSlots
