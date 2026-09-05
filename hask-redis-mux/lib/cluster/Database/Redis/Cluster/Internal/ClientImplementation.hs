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
-- Runtime 'auth' is intentionally unsupported because it cannot authenticate
-- every physical cluster connection; use
-- 'createClusterClientWithAuthentication' instead.
--
-- For advanced use (e.g.\ forwarding raw RESP commands), the low-level
-- 'executeKeyedClusterCommand' and 'executeKeylessClusterCommand' are also
-- available but are not re-exported by the convenience "Redis" module.
--
-- @since 0.1.0.0
module Database.Redis.Cluster.Internal.ClientImplementation
  ( -- * Client Types
    ClusterClient (..),
    ClusterCommandClient,
    ClusterError (..),
    ClusterConfig (..),
    ClusterAuthentication (..),
    ClusterAuthenticationException (..),
    ClusterRuntimeAuthenticationUnsupported (..),
    -- * Client Lifecycle
    createClusterClient,
    createClusterClientWithAuthentication,
    createClusterClientWithBoundedConnector,
    createClusterClientWithFactories,
    closeClusterClient,
    withClusterClient,
    withClusterClientAuthentication,
    refreshTopology,
    -- * Running Commands (monadic, recommended)
    runClusterCommandClient,
    -- * Low-Level Command Execution (advanced)
    -- | These are intended for internal use or advanced scenarios like RESP
    -- proxying. Prefer 'runClusterCommandClient' with 'RedisCommands' for
    -- normal Redis operations.
    executeKeyedClusterCommand,
    executeKeyedClusterCommandUsingDelay,
    executeKeylessClusterCommand,
    executeKeylessClusterCommandUsingDelay,
    executeRawClusterCommand,
    executeRawClusterCommandUsingDelay,
    RawClusterRoute (..),
    -- * Re-export RedisCommands for convenience
    module RedisCommandClient,
    -- * Internal (exported for testing)
    RedirectionInfo (..),
    RetryRoute (..),
    classifyClusterReply,
    parseRedirectionError,
    detectRedirection,
    withRetryAndRefreshUsing,
  )
where

import           Control.Concurrent                       (threadDelay)
import           Control.Concurrent.MVar                  (MVar, newMVar,
                                                           putMVar, tryTakeMVar)
import           Control.Concurrent.STM                   (TVar, atomically,
                                                           newTVarIO,
                                                           readTVarIO)
import           Control.Exception                        (Exception,
                                                           SomeAsyncException,
                                                           SomeException,
                                                           bracket, finally,
                                                           fromException,
                                                           onException, throwIO,
                                                           try)
import           Control.Monad                            (void, when)
import           Control.Monad.IO.Class                   (MonadIO (..))
import qualified Control.Monad.State                      as State
import           Data.ByteString                          (ByteString)
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Builder                  as Builder
import qualified Data.ByteString.Char8                    as BS8
import           Data.List                                (foldl')
import qualified Data.Map.Strict                          as Map
import           Data.Time.Clock                          (NominalDiffTime,
                                                           diffUTCTime,
                                                           getCurrentTime)
import           Data.Word                                (Word16)
import           Database.Redis.Client                    (Client (..),
                                                           ConnectionStatus (..))
import           Database.Redis.Cluster                   (ClusterNode (..),
                                                           ClusterTopology (..),
                                                           NodeAddress (..),
                                                           NodeRole (..),
                                                           calculateSlot,
                                                           findNodeAddressForSlot,
                                                           parseClusterSlots)
import           Database.Redis.Cluster.ConnectionPool    (ConnectionPool,
                                                           ConnectionPoolException (..),
                                                           PoolConfig (..),
                                                           closePool,
                                                           createPool,
                                                           withConnection,
                                                           withConnectionBounded)
import           Database.Redis.Cluster.Internal.Topology (commitRefreshedTopology,
                                                           patchMovedSlot)
import           Database.Redis.Command                   (ClientReplyModeUnsupported (..),
                                                           ClientReplyValues (OFF),
                                                           ClientState (..),
                                                           RedisCommandClient (..),
                                                           RedisCommands (..),
                                                           convertResp,
                                                           encodeCommandBuilder,
                                                           geoRadiusFlagToList,
                                                           geoSearchByToList,
                                                           geoSearchFromToList,
                                                           geoSearchOptionToList,
                                                           geoUnitKeyword,
                                                           parseWith,
                                                           runRedisCommandClient,
                                                           showBS)
import qualified Database.Redis.Command                   as RedisCommandClient
import           Database.Redis.Connector                 (ConnectionPhase (..),
                                                           ConnectionSetupException,
                                                           ConnectionSupervisor (..),
                                                           Connector,
                                                           withConnectionTimeout,
                                                           withConnectionTimeoutSupervised)
import           Database.Redis.FromResp                  (FromResp (..))
import           Database.Redis.Internal.MultiplexPool    (MultiplexPool,
                                                           MultiplexPoolException (..),
                                                           closeMultiplexPool,
                                                           createMultiplexPool,
                                                           submitToNode,
                                                           submitToNodeWithAsking)
import           Database.Redis.Resp                      (Encodable (..),
                                                           RespData (..))

-- | Error types specific to cluster operations.
data ClusterError
  = MovedError Word16 NodeAddress -- ^ Permanent redirect: the slot has migrated to a different node.
  | AskError Word16 NodeAddress -- ^ Temporary redirect during slot migration; retry at the given node.
  | ClusterDownError String -- ^ The cluster is in a down or error state.
  | TryAgainError String -- ^ Transient failure; the operation should be retried.
  | CrossSlotError String -- ^ Multi-key command spans multiple hash slots.
  | RedisCommandError ByteString -- ^ An ordinary Redis server error reply, preserved verbatim.
  | MaxRetriesExceeded String -- ^ All retry attempts exhausted.
  | TopologyError String -- ^ Slot or node lookup failed (e.g., empty topology).
  | ConnectionError String -- ^ Network-level failure connecting to a node.
  | ConnectionTimeoutError ConnectionSetupException -- ^ A bounded connection setup attempt timed out.
  | ClusterAuthenticationError ClusterAuthenticationException -- ^ A physical connection could not authenticate.
  | ClusterClientClosed -- ^ The client has been terminally closed.
  deriving (Show, Eq)

newtype TopologyValidationException = TopologyValidationException String
  deriving (Show)

instance Exception TopologyValidationException

-- | Redirection information parsed from errors
data RedirectionInfo = RedirectionInfo
  { redirSlot :: Word16,
    redirHost :: String,
    redirPort :: Int
  }
  deriving (Show, Eq)

data RetryRoute
  = RouteBySlot
  | RouteMoved !Word16 !NodeAddress
  | RouteAsk !NodeAddress

-- | Explicit routing policy for a pre-parsed RESP frame.
--
-- This is deliberately separate from 'RetryRoute': callers choose the initial
-- cluster routing policy, while retry routes are determined from server replies.
data RawClusterRoute
  = RawRouteByKey !ByteString
  | RawRouteKeyless
  deriving (Eq, Show)

-- | Configuration for a cluster client.
data ClusterConfig = ClusterConfig
  { clusterSeedNode                :: NodeAddress -- ^ Initial node used to discover the cluster topology.
  , clusterPoolConfig              :: PoolConfig  -- ^ Connection pool settings applied to every node.
  , clusterMaxRetries              :: Int -- ^ Maximum retry attempts on MOVED\/ASK\/transient errors (default: 3).
  , clusterRetryDelay              :: Int -- ^ Initial retry delay in microseconds; doubled on each retry (default: 100000 = 100ms).
  , clusterTopologyRefreshInterval :: Int -- ^ Seconds between automatic background topology refreshes (default: 600 = 10 min).
  }
  deriving (Show)

-- | Authentication applied once to every physical cluster connection before
-- it is used for topology discovery, pooling, multiplexing, or redirects.
--
-- Password authentication sends @AUTH password@. ACL authentication sends
-- @HELLO 2 AUTH username password@, explicitly retaining RESP2.
data ClusterAuthentication
  = ClusterPassword !ByteString
  | ClusterACL !ByteString !ByteString
  deriving (Eq)

instance Show ClusterAuthentication where
  show (ClusterPassword _) = "ClusterPassword <redacted>"
  show (ClusterACL _ _)    = "ClusterACL <redacted> <redacted>"

-- | Authentication failed for a physical connection. The server response and
-- credentials are intentionally omitted.
newtype ClusterAuthenticationException
  = ClusterAuthenticationFailed NodeAddress
  deriving (Eq, Show)

instance Exception ClusterAuthenticationException

-- | Runtime cluster authentication is unsupported because Redis credentials
-- are connection-scoped. Configure authentication during client construction.
data ClusterRuntimeAuthenticationUnsupported
  = ClusterRuntimeAuthenticationUnsupported
  deriving (Eq, Show)

instance Exception ClusterRuntimeAuthenticationUnsupported

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
  createClusterClientWithFactoriesUsing
    False createPool createMultiplexPool config connector

-- | Construct a cluster client whose every physical connection is
-- authenticated before first use. Authentication shares the configured
-- per-attempt connection deadline and abortively closes failed transports.
createClusterClientWithAuthentication
  :: (Client client)
  => ClusterConfig
  -> ClusterAuthentication
  -> Connector client
  -> IO (ClusterClient client)
createClusterClientWithAuthentication config authentication connector =
  createClusterClientWithBoundedConnector config authenticatedConnector
  where
    authenticatedConnector =
      withConnectionTimeoutSupervised
        (connectionTimeout $ clusterPoolConfig config)
        initialPhase $ \supervisor addr -> do
          conn <- connector addr
          cleanup <- registerConnectedTransport supervisor conn
          setConnectionPhase supervisor Authentication
          authenticateClusterConnection authentication addr conn
            `onException` cleanup
    initialPhase
      | useTLS (clusterPoolConfig config) = TLSConnectionSetup
      | otherwise = PlaintextConnectionSetup

authenticateClusterConnection
  :: (Client client)
  => ClusterAuthentication
  -> NodeAddress
  -> client 'Connected
  -> IO (client 'Connected)
authenticateClusterConnection authentication addr conn = do
  outcome <- try $ State.evalStateT
    (runRedisCommandClient authenticationAction)
    (ClientState conn BS8.empty)
  case outcome of
    Right response ->
      case response of
        RespError _ -> throwIO $ ClusterAuthenticationFailed addr
        _           -> return conn
    Left (err :: SomeException) ->
      case fromException err of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing    -> throwIO $ ClusterAuthenticationFailed addr
  where
    authenticationAction =
      case authentication of
        ClusterPassword password ->
          RedisCommandClient.authenticatePassword password
        ClusterACL username password ->
          RedisCommandClient.authenticateACL username password

-- | Construct a cluster client from a phase-aware connector that already owns
-- its complete setup deadline, including authentication when applicable.
createClusterClientWithBoundedConnector ::
  (Client client) =>
  ClusterConfig ->
  Connector client ->
  IO (ClusterClient client)
createClusterClientWithBoundedConnector config connector =
  createClusterClientWithFactoriesUsing
    True createPool createMultiplexPool config connector

-- | Internal construction seam for deterministic failure-injection tests.
createClusterClientWithFactories
  :: (Client client)
  => (PoolConfig -> IO (ConnectionPool client))
  -> (Connector client -> Int -> IO (MultiplexPool client))
  -> ClusterConfig
  -> Connector client
  -> IO (ClusterClient client)
createClusterClientWithFactories createConnectionPool createMuxPool config connector = do
  createClusterClientWithFactoriesUsing
    False createConnectionPool createMuxPool config connector

createClusterClientWithFactoriesUsing
  :: (Client client)
  => Bool
  -> (PoolConfig -> IO (ConnectionPool client))
  -> (Connector client -> Int -> IO (MultiplexPool client))
  -> ClusterConfig
  -> Connector client
  -> IO (ClusterClient client)
createClusterClientWithFactoriesUsing connectorIsBounded
    createConnectionPool createMuxPool config connector = do
  pool <- createConnectionPool (clusterPoolConfig config)
  build pool `onException` closePool pool
  where
    build pool = do
  -- Discover initial topology before creating TVar
      let seedNode = clusterSeedNode config
      let connectFromPool =
            if connectorIsBounded
              then withConnectionBounded
              else withConnection
      response <- connectFromPool pool seedNode connector $ \conn -> do
        let clientState = ClientState conn BS8.empty
        State.evalStateT (runRedisCommandClient clusterSlots) clientState

      currentTime <- getCurrentTime
      case parseClusterSlots response currentTime of
        Left err -> throwIO $ TopologyValidationException err
        Right initialTopology -> do
          topology <- newTVarIO initialTopology
          refreshLock <- newMVar ()
          let poolCfg = clusterPoolConfig config
              phase =
                if useTLS poolCfg
                  then TLSConnectionSetup
                  else PlaintextConnectionSetup
              boundedConnector
                | connectorIsBounded = connector
                | otherwise =
                    withConnectionTimeout
                      (connectionTimeout poolCfg) phase connector
          muxPool <- createMuxPool boundedConnector 1
          return $ ClusterClient topology pool config boundedConnector refreshLock muxPool

-- | Close all pooled connections across every node.
-- Closure is terminal and idempotent: owned transports are closed exactly once,
-- and later commands return 'ClusterClientClosed' without reconnecting.
--
-- Consider using 'withClusterClient' instead for automatic cleanup.
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = do
  closeMultiplexPool (clusterMultiplexPool client)
  closePool (clusterConnectionPool client)

-- | Bracket-style resource management for cluster clients.
--
-- Creates a client, runs the given action, and ensures the client is closed
-- even if an exception occurs. Prefer this over manual 'createClusterClient'
-- and 'closeClusterClient'. After the callback returns, both backing pools are
-- permanently closed.
--
-- @
-- withClusterClient config connector $ \\client ->
--   runClusterCommandClient client $ do
--     set \"key\" \"value\"
--     get \"key\"
-- @
withClusterClient
  :: (Client client)
  => ClusterConfig
  -> Connector client
  -> (ClusterClient client -> IO a)
  -> IO a
withClusterClient config connector =
  bracket (createClusterClient config connector) closeClusterClient

-- | Bracket-style authenticated cluster construction. The supplied
-- credentials are applied independently to every physical connection.
withClusterClientAuthentication
  :: (Client client)
  => ClusterConfig
  -> ClusterAuthentication
  -> Connector client
  -> (ClusterClient client -> IO a)
  -> IO a
withClusterClientAuthentication config authentication connector =
  bracket
    (createClusterClientWithAuthentication config authentication connector)
    closeClusterClient

-- | Refresh cluster topology by querying known masters and then the seed.
-- Uses a lock to prevent thundering herd: if another thread is already
-- refreshing, this call returns immediately (the other thread's refresh
-- will update the shared topology).
refreshTopology ::
  (Client client) =>
  ClusterClient client ->
  IO ()
refreshTopology client = do
  result <- refreshTopologyFromCandidates client [] []
  case result of
    Right () -> return ()
    Left err -> throwRefreshError err
  where
    throwRefreshError (TopologyError err) =
      throwIO $ TopologyValidationException err
    throwRefreshError (ConnectionTimeoutError err) = throwIO err
    throwRefreshError (ClusterAuthenticationError err) = throwIO err
    throwRefreshError ClusterClientClosed = throwIO ConnectionPoolClosed
    throwRefreshError err = throwIO $ userError $ show err

refreshTopologyFromCandidates
  :: (Client client)
  => ClusterClient client
  -> [NodeAddress]
  -> [(Word16, NodeAddress)]
  -> IO (Either ClusterError ())
refreshTopologyFromCandidates client preferred protectedPatches = do
  acquired <- tryTakeMVar (clusterRefreshLock client)
  case acquired of
    Nothing -> return $ Right ()
    Just _  ->
      finally doRefresh (putMVar (clusterRefreshLock client) ())
  where
    doRefresh = do
      baseline <- readTVarIO $ clusterTopology client
      tryCandidates baseline $ refreshCandidates baseline

    refreshCandidates topology =
      take candidateLimit $ uniqueAddresses $
        preferred
          ++ knownMasters topology
          ++ [clusterSeedNode $ clusterConfig client]

    candidateLimit = max 1 $ clusterMaxRetries $ clusterConfig client

    knownMasters topology =
      [ nodeAddress node
      | node <- Map.elems $ topologyNodes topology
      , nodeRole node == Master
      , not $ null $ nodeSlotsServed node
      ]

    uniqueAddresses = foldl'
      (\addresses address ->
        if address `elem` addresses
          then addresses
          else addresses ++ [address])
      []

    tryCandidates _ [] =
      return $ Left $ ConnectionError "No topology refresh candidates available"
    tryCandidates baseline (candidate : candidates) = do
      result <- fetchTopology candidate
      case result of
        Right topology -> do
          atomically $ commitRefreshedTopology
            (clusterTopology client) protectedPatches topology
          return $ Right ()
        Left err ->
          case candidates of
            [] -> return $ Left err
            _  -> tryCandidates baseline candidates

    fetchTopology candidate = do
      response <- executeOnNode client candidate clusterSlots $
        clusterConnector client
      case response of
        Left err -> return $ Left err
        Right payload -> do
          currentTime <- getCurrentTime
          return $
            case parseClusterSlots payload currentTime of
              Left err       -> Left $ TopologyError err
              Right topology -> Right topology

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

-- | Classify every Redis error reply returned by a cluster command.
--
-- Prefixes are case-sensitive and must end at the error token boundary.
-- Malformed redirections and unrecognized server errors remain ordinary
-- 'RedisCommandError' values with their full payload preserved.
{-# INLINE classifyClusterReply #-}
classifyClusterReply :: RespData -> Either ClusterError RespData
classifyClusterReply (RespError msg)
  | Just redirection <- classifyRedirection msg =
      case redirection of
        Left (RedirectionInfo slot host port) ->
          Left $ MovedError slot $ NodeAddress host port
        Right (RedirectionInfo slot host port) ->
          Left $ AskError slot $ NodeAddress host port
  | hasErrorPrefix "TRYAGAIN" msg =
      Left $ TryAgainError $ BS8.unpack msg
  | hasErrorPrefix "CLUSTERDOWN" msg =
      Left $ ClusterDownError $ BS8.unpack msg
  | hasErrorPrefix "CROSSSLOT" msg =
      Left $ CrossSlotError $ BS8.unpack msg
  | otherwise = Left $ RedisCommandError msg
classifyClusterReply respData = Right respData

{-# INLINE hasErrorPrefix #-}
hasErrorPrefix :: ByteString -> ByteString -> Bool
hasErrorPrefix prefix message =
  message == prefix
    || (prefix `BS.isPrefixOf` message
      && BS.length message > BS.length prefix
      && BS.index message (BS.length prefix) == 0x20)

{-# INLINE classifyRedirection #-}
classifyRedirection
  :: ByteString
  -> Maybe (Either RedirectionInfo RedirectionInfo)
classifyRedirection message
  | "MOVED " `BS.isPrefixOf` message =
      Left <$> parseMovedAsk (BS.drop 6 message)
  | "ASK " `BS.isPrefixOf` message =
      Right <$> parseMovedAsk (BS.drop 4 message)
  | otherwise = Nothing

-- | Backward-compatible MOVED/ASK-only view of 'classifyClusterReply'.
{-# INLINE detectRedirection #-}
detectRedirection :: RespData -> Maybe (Either RedirectionInfo RedirectionInfo)
detectRedirection (RespError message) = classifyRedirection message
detectRedirection _                   = Nothing

-- | Execute a command on a specific node (used for keyless commands and topology refresh)
executeOnNode ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client RespData ->
  Connector client ->
  IO (Either ClusterError RespData)
executeOnNode client nodeAddr action connector = do
  result <- tryClusterAction $
    withConnectionBounded
      (clusterConnectionPool client) nodeAddr connector $ \conn -> do
    let clientState = ClientState conn BS8.empty
    State.evalStateT (runRedisCommandClient action) clientState

  return $ result >>= classifyClusterReply

-- | Execute a command that does not target a specific key (e.g., PING, AUTH, FLUSHALL).
-- Routed to an arbitrary master node.
executeKeylessClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  RedisCommandClient client RespData ->
  IO (Either ClusterError RespData)
executeKeylessClusterCommand =
  executeKeylessClusterCommandUsingDelay threadDelay

-- | Test seam for deterministic keyless retry schedules.
executeKeylessClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  RedisCommandClient client RespData ->
  IO (Either ClusterError RespData)
executeKeylessClusterCommandUsingDelay delayAction client action =
  withRetryAndRefreshPolicyUsing
    KeylessRetryPolicy
    delayAction
    client
    (clusterMaxRetries $ clusterConfig client)
    (clusterRetryDelay $ clusterConfig client)
    (const $ executeKeylessAttempt client action)

executeKeylessAttempt ::
  (Client client) =>
  ClusterClient client ->
  RedisCommandClient client RespData ->
  IO (Either ClusterError RespData)
executeKeylessAttempt client action = do
  let connector = clusterConnector client
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  case masterNodes of
    []       -> return $ Left $ TopologyError "No master nodes available"
    (node:_) -> executeOnNode client (nodeAddress node) action connector

-- | Retry logic for transient failures and Redis redirections.
--
-- MOVED retries go directly to the authoritative target without ASKING. The
-- affected slot is patched before retrying, and a bounded full refresh follows
-- a successful direct retry. Refresh candidates include the redirect target,
-- known masters, and the original seed.
--
-- Performance considerations:
-- - Concurrent MOVED patches are retained across an in-flight stale refresh
-- - Each refresh costs ~1-5ms (network + parsing)
-- - A single refresh lock prevents a thundering herd
--
-- ASK errors follow the Redis protocol: retry at the target node with an ASKING prefix.
-- No topology refresh is needed since ASK indicates a temporary, in-progress migration.
-- | Deterministic retry seam used by tests and timing-sensitive integrations.
-- Production command execution supplies 'threadDelay'.
withRetryAndRefreshUsing ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  Int ->
  Int ->
  (RetryRoute -> IO (Either ClusterError a)) ->
  IO (Either ClusterError a)
withRetryAndRefreshUsing delayAction client maxRetries initialDelay action =
  withRetryAndRefreshPolicyUsing
    KeyedRetryPolicy delayAction client maxRetries initialDelay action

data RetryPolicy
  = KeyedRetryPolicy
  | KeylessRetryPolicy
  deriving (Eq)

withRetryAndRefreshPolicyUsing ::
  (Client client) =>
  RetryPolicy ->
  (Int -> IO ()) ->
  ClusterClient client ->
  Int ->
  Int ->
  (RetryRoute -> IO (Either ClusterError a)) ->
  IO (Either ClusterError a)
withRetryAndRefreshPolicyUsing retryPolicy delayAction
    client maxRetries initialDelay action =
  go 0 initialDelay RouteBySlot
  where
    go attempt delay route
      | attempt >= maxRetries =
          return $ Left $ MaxRetriesExceeded $
            "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action route
          case result of
            Right value -> do
              case route of
                RouteMoved slot address ->
                  void $ refreshTopologyFromCandidates
                    client [address] [(slot, address)]
                _ -> return ()
              return $ Right value
            Left err@(TryAgainError _) ->
              retryAfterDelay err route delay
            Left err@(ClusterDownError _) -> do
              if attempt + 1 >= maxRetries
                then return $ retryExhausted maxRetries err
                else do
                  refreshResult <- refreshForRoute route
                  case refreshResult of
                    Left ClusterClientClosed ->
                      return $ Left ClusterClientClosed
                    _ -> retryAfterDelay err RouteBySlot delay
            Left err@(MovedError slot address)
              | retryPolicy == KeyedRetryPolicy -> do
                  atomically $ patchMovedSlot (clusterTopology client) slot address
                  retryImmediately err $ RouteMoved slot address
            Left err@(AskError _ address)
              | retryPolicy == KeyedRetryPolicy ->
                  retryImmediately err $ RouteAsk address
            Left err@(ConnectionError _)
              | retryPolicy == KeyedRetryPolicy -> do
                  refreshResult <- refreshForRoute route
                  case refreshResult of
                    Left ClusterClientClosed ->
                      return $ Left ClusterClientClosed
                    Left refreshErr@(TopologyError _) ->
                      return $ Left refreshErr
                    _ -> retryAfterDelay err RouteBySlot delay
            Left err@(ConnectionTimeoutError _)
              | retryPolicy == KeyedRetryPolicy -> do
                  refreshResult <- case route of
                    RouteMoved _ _ -> refreshForRoute route
                    _              -> return $ Right ()
                  case refreshResult of
                    Left ClusterClientClosed ->
                      return $ Left ClusterClientClosed
                    Left refreshErr@(TopologyError _) ->
                      return $ Left refreshErr
                    _ -> retryAfterDelay err RouteBySlot delay
            Left err -> return $ Left err

      where
        retryImmediately err nextRoute
          | attempt + 1 >= maxRetries =
              return $ retryExhausted maxRetries err
          | otherwise =
              go (attempt + 1) delay nextRoute

        retryAfterDelay err nextRoute currentDelay
          | attempt + 1 >= maxRetries =
              return $ retryExhausted maxRetries err
          | otherwise = do
              delayAction $ normalizeDelay currentDelay
              go (attempt + 1) (nextRetryDelay currentDelay) nextRoute

    refreshForRoute (RouteMoved slot address) =
      refreshTopologyFromCandidates client [address] [(slot, address)]
    refreshForRoute _ =
      refreshTopologyFromCandidates client [] []

retryExhausted :: Int -> ClusterError -> Either ClusterError a
retryExhausted maxRetries lastError =
  Left $ MaxRetriesExceeded $
    "Max retries (" ++ show maxRetries
      ++ ") exceeded; last error: " ++ show lastError

normalizeDelay :: Int -> Int
normalizeDelay = max 0

nextRetryDelay :: Int -> Int
nextRetryDelay delay
  | normalized > maxBound `div` 2 = maxBound
  | otherwise = normalized * 2
  where
    normalized = normalizeDelay delay

tryClusterAction :: IO a -> IO (Either ClusterError a)
tryClusterAction action = do
  result <- try action
  case result of
    Right value -> return $ Right value
    Left (e :: SomeException) ->
      case fromException e of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing
          | Just ConnectionPoolClosed <- fromException e ->
              return $ Left ClusterClientClosed
          | Just MultiplexPoolClosed <- fromException e ->
              return $ Left ClusterClientClosed
          | Just timeoutError <- fromException e ->
              return $ Left $ ConnectionTimeoutError timeoutError
          | Just authenticationError <- fromException e ->
              return $ Left $ ClusterAuthenticationError authenticationError
          | Just (TopologyValidationException err) <- fromException e ->
              return $ Left $ TopologyError err
          | otherwise ->
              return $ Left $ ConnectionError $ show e

-- | Parse the payload after "MOVED " or "ASK " prefix.
-- Input format: "3999 127.0.0.1:6381" (slot, space, host:port)
-- Avoids BS8.words allocation by using break/drop directly.
{-# INLINE parseMovedAsk #-}
parseMovedAsk :: ByteString -> Maybe RedirectionInfo
parseMovedAsk rest =
  case BS8.readInt rest of
    Just (slot, afterSlot)
      | slot >= 0
      , slot <= 16383
      , not (BS8.null afterSlot)
      , BS8.head afterSlot == ' '
      -> let hostPort = BS8.tail afterSlot
         in case BS8.break (== ':') hostPort of
              (host, portPart)
                | not (BS8.null host)
                , not (BS8.null portPart)
                -> case BS8.readInt (BS8.tail portPart) of
                     Just (port, rest')
                       | port >= 1
                       , port <= 65535
                       , BS8.null rest'
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
  RedisCommandClient client RespData ->
  ClusterCommandClient client (Either ClusterError RespData)
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
executeKeyless
  :: (Client client, FromResp a)
  => RedisCommandClient client RespData
  -> ClusterCommandClient client a
executeKeyless action = do
  result <- executeKeylessCommand action
  raw <- unwrapClusterResult result
  convertResp raw

executeKeylessMaybe
  :: (Client client)
  => RedisCommandClient client (Maybe RespData)
  -> ClusterCommandClient client (Maybe RespData)
executeKeylessMaybe action = do
  client <- State.get
  result <- liftIO $
    withRetryAndRefreshPolicyUsing
      KeylessRetryPolicy
      threadDelay
      client
      (clusterMaxRetries $ clusterConfig client)
      (clusterRetryDelay $ clusterConfig client)
      (const $ executeKeylessMaybeAttempt client action)
  unwrapClusterResult result

executeKeylessMaybeAttempt
  :: (Client client)
  => ClusterClient client
  -> RedisCommandClient client (Maybe RespData)
  -> IO (Either ClusterError (Maybe RespData))
executeKeylessMaybeAttempt client action = do
  topology <- readTVarIO $ clusterTopology client
  let masters =
        [ node
        | node <- Map.elems $ topologyNodes topology
        , nodeRole node == Master
        ]
  case masters of
    [] -> return $ Left $ TopologyError "No master nodes available"
    node : _ -> do
      result <- tryClusterAction $
        withConnectionBounded
          (clusterConnectionPool client)
          (nodeAddress node)
          (clusterConnector client) $ \conn -> do
            let clientState = ClientState conn BS8.empty
            State.evalStateT
              (runRedisCommandClient action)
              clientState
      return $ result >>= traverse classifyClusterReply

-- | Execute a keyed command via the multiplexer pool.
-- Pre-encodes the command to a Builder, routes by slot, and handles MOVED/ASK redirection.
-- Every @RespError@ is returned as a typed 'ClusterError'; ordinary Redis
-- errors use 'RedisCommandError' and are never success-shaped.
--
-- This is the low-level API for executing commands with explicit routing key.
-- For most operations, prefer 'runClusterCommandClient' with 'RedisCommands'.
executeKeyedClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  ByteString ->           -- key for routing
  [ByteString] ->         -- command args
  IO (Either ClusterError RespData)
executeKeyedClusterCommand =
  executeKeyedClusterCommandUsingDelay threadDelay

-- | Test seam for deterministic retry schedule and cancellation coverage.
executeKeyedClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  ByteString ->
  [ByteString] ->
  IO (Either ClusterError RespData)
executeKeyedClusterCommandUsingDelay delayAction client key cmdArgs = do
  let muxPool = clusterMultiplexPool client
      cmdBuilder = encodeCommandBuilder cmdArgs
      !slot = calculateSlot key
  withRetryAndRefreshUsing delayAction
    client
    (clusterMaxRetries $ clusterConfig client)
    (clusterRetryDelay $ clusterConfig client) $ \route ->
    case route of
      RouteBySlot -> do
        refreshResult <- tryClusterAction $ refreshTopologyIfStale client
        case refreshResult of
          Left err -> return $ Left err
          Right () -> executeOnSlotMux client muxPool slot cmdBuilder
      RouteMoved _ address ->
        executeOnNodeDirect muxPool address cmdBuilder
      RouteAsk address ->
        executeOnNodeWithAsking client muxPool address cmdBuilder

-- | Execute an already parsed RESP frame with an explicit cluster routing
-- policy.  The frame is encoded once and that exact builder is reused for each
-- retry, redirect, and reconnect attempt.
--
-- This is intentionally a low-level API for protocol adapters.  It does not
-- classify commands or convert RESP values to command argument lists.
executeRawClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  RawClusterRoute ->
  RespData ->
  IO (Either ClusterError RespData)
executeRawClusterCommand =
  executeRawClusterCommandUsingDelay threadDelay

-- | Deterministic-delay variant of 'executeRawClusterCommand'.
executeRawClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  RawClusterRoute ->
  RespData ->
  IO (Either ClusterError RespData)
executeRawClusterCommandUsingDelay delayAction client rawRoute frame =
  case rawRoute of
    RawRouteByKey key ->
      executeRawKeyed
        delayAction client (calculateSlot key) frameBuilder
    RawRouteKeyless ->
      withRetryAndRefreshPolicyUsing
        KeylessRetryPolicy
        delayAction
        client
        (clusterMaxRetries $ clusterConfig client)
        (clusterRetryDelay $ clusterConfig client)
        (const $ executeKeylessFrameAttempt client frameBuilder)
  where
    frameBuilder = encode frame

executeRawKeyed ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  Word16 ->
  Builder.Builder ->
  IO (Either ClusterError RespData)
executeRawKeyed delayAction client slot frameBuilder =
  withRetryAndRefreshUsing
    delayAction
    client
    (clusterMaxRetries $ clusterConfig client)
    (clusterRetryDelay $ clusterConfig client) $ \route ->
    case route of
      RouteBySlot -> do
        refreshResult <- tryClusterAction $ refreshTopologyIfStale client
        case refreshResult of
          Left err -> return $ Left err
          Right () ->
            executeOnSlotMux client (clusterMultiplexPool client) slot frameBuilder
      RouteMoved _ address ->
        executeOnNodeDirect (clusterMultiplexPool client) address frameBuilder
      RouteAsk address ->
        executeOnNodeWithAsking client (clusterMultiplexPool client) address frameBuilder

executeKeylessFrameAttempt ::
  (Client client) =>
  ClusterClient client ->
  Builder.Builder ->
  IO (Either ClusterError RespData)
executeKeylessFrameAttempt client frameBuilder = do
  topology <- readTVarIO $ clusterTopology client
  let masterNodes =
        [ node
        | node <- Map.elems $ topologyNodes topology
        , nodeRole node == Master
        ]
  case masterNodes of
    []       -> return $ Left $ TopologyError "No master nodes available"
    (node:_) ->
      executeOnNode
        client
        (nodeAddress node)
        (rawFrameAction frameBuilder)
        (clusterConnector client)

rawFrameAction :: (Client client) => Builder.Builder -> RedisCommandClient client RespData
rawFrameAction frameBuilder = RedisCommandClient $ do
  ClientState conn _ <- State.get
  liftIO $ send conn (Builder.toLazyByteString frameBuilder)
  parseWith (receive conn)

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
      result <- tryClusterAction $ submitToNode muxPool addr cmdBuilder
      return $ result >>= classifyClusterReply

executeOnNodeDirect
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder
  -> IO (Either ClusterError RespData)
executeOnNodeDirect muxPool address cmdBuilder = do
  result <- tryClusterAction $ submitToNode muxPool address cmdBuilder
  return $ result >>= classifyClusterReply

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
  result <- tryClusterAction $
    submitToNodeWithAsking muxPool addr askingBuilder cmdBuilder
  return $ result >>= classifyClusterReply

instance (Client client) => RedisCommands (ClusterCommandClient client) where
  auth _ _ = liftIO $ throwIO ClusterRuntimeAuthenticationUnsupported
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
  clientReply OFF = liftIO $ throwIO (ClientReplyModeUnsupported OFF)
  clientReply val = executeKeylessMaybe (RedisCommandClient.clientReply val)
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
