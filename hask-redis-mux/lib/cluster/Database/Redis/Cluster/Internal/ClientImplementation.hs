{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE ViewPatterns      #-}

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
    RedisClientError (..),
    RedisClusterFailure (..),
    RedisLifecycleFailure (..),
    RedisProtocolFailure (..),
    ClusterError,
    pattern MovedError,
    pattern AskError,
    pattern ClusterDownError,
    pattern TryAgainError,
    pattern CrossSlotError,
    pattern RedisCommandError,
    pattern MaxRetriesExceeded,
    pattern TopologyError,
    pattern ConnectionError,
    pattern ConnectionTimeoutError,
    pattern ClusterAuthenticationError,
    pattern ClusterClientClosed,
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

import           Control.Concurrent                             (threadDelay)
import           Control.Concurrent.MVar                        (MVar, newMVar,
                                                                 putMVar,
                                                                 tryTakeMVar)
import           Control.Concurrent.STM                         (TVar,
                                                                 atomically,
                                                                 newTVarIO,
                                                                 readTVarIO)
import           Control.Exception                              (Exception,
                                                                 SomeAsyncException,
                                                                 SomeException,
                                                                 bracket,
                                                                 finally,
                                                                 fromException,
                                                                 onException,
                                                                 throwIO,
                                                                 toException,
                                                                 try)
import           Control.Monad                                  (void, when)
import           Control.Monad.IO.Class                         (MonadIO (..))
import qualified Control.Monad.State                            as State
import           Data.ByteString                                (ByteString)
import qualified Data.ByteString                                as BS
import qualified Data.ByteString.Builder                        as Builder
import qualified Data.ByteString.Char8                          as BS8
import           Data.List                                      (foldl')
import qualified Data.Map.Strict                                as Map
import           Data.Time.Clock                                (NominalDiffTime,
                                                                 diffUTCTime,
                                                                 getCurrentTime)
import           Data.Word                                      (Word16)
import           Database.Redis.Client                          (Client (..),
                                                                 ConnectionStatus (..))
import           Database.Redis.Cluster                         (ClusterNode (..),
                                                                 ClusterTopology (..),
                                                                 NodeAddress (..),
                                                                 NodeRole (..),
                                                                 calculateSlot,
                                                                 findNodeAddressForSlot,
                                                                 parseClusterSlots)
import           Database.Redis.Cluster.ConnectionPool          (ConnectionPool,
                                                                 ConnectionPoolException (..),
                                                                 PoolConfig (..),
                                                                 closePool,
                                                                 createPool,
                                                                 withConnection,
                                                                 withConnectionBounded)
import           Database.Redis.Cluster.Internal.CommandGrammar (CommandFrameRouting (..),
                                                                 classifyCommandFrame,
                                                                 renderCommandGrammarError)
import           Database.Redis.Cluster.Internal.Topology       (commitRefreshedTopology,
                                                                 patchMovedSlot)
import           Database.Redis.Command                         (ClientReplyModeUnsupported (..),
                                                                 ClientReplyValues (ON),
                                                                 ClientState (..),
                                                                 CommandDescriptor,
                                                                 CommandRoute (..),
                                                                 RedisCommandClient (..),
                                                                 RedisCommands (..),
                                                                 convertResp,
                                                                 encodeCommandBuilder,
                                                                 executeCommandDescriptor,
                                                                 parseWith,
                                                                 runRedisCommandClient)
import qualified Database.Redis.Command                         as RedisCommandClient
import           Database.Redis.Connector                       (ConnectionPhase (..),
                                                                 ConnectionSetupException,
                                                                 ConnectionSupervisor (..),
                                                                 Connector,
                                                                 withConnectionTimeout,
                                                                 withConnectionTimeoutSupervised)
import           Database.Redis.FromResp                        (FromResp (..))
import           Database.Redis.Internal.Multiplexer            (MultiplexerException (..))
import           Database.Redis.Internal.MultiplexPool          (MultiplexPool,
                                                                 MultiplexPoolException (..),
                                                                 closeMultiplexPool,
                                                                 createMultiplexPool,
                                                                 submitToNode,
                                                                 submitToNodeWithAsking)
import           Database.Redis.RedisError                      (RedisClientError (..),
                                                                 RedisClusterFailure (..),
                                                                 RedisLifecycleFailure (..),
                                                                 RedisProtocolFailure (..),
                                                                 tryRedisClient)
import           Database.Redis.Resp                            (Encodable (..),
                                                                 RespData (..))

-- | Deprecated compatibility name. All cluster operations now return the
-- unified 'RedisClientError' root.
type ClusterError = RedisClientError

pattern MovedError :: Word16 -> NodeAddress -> RedisClientError
pattern MovedError slot address <-
  (matchMoved -> Just (slot, address))
  where
    MovedError slot (NodeAddress host port) =
      RedisClusterError $ RedisMoved slot host port

pattern AskError :: Word16 -> NodeAddress -> RedisClientError
pattern AskError slot address <-
  (matchAsk -> Just (slot, address))
  where
    AskError slot (NodeAddress host port) =
      RedisClusterError $ RedisAsk slot host port

pattern ClusterDownError :: String -> RedisClientError
pattern ClusterDownError message <-
  (matchClusterDown -> Just message)
  where
    ClusterDownError message =
      RedisClusterError $ RedisClusterDown $ BS8.pack message

pattern TryAgainError :: String -> RedisClientError
pattern TryAgainError message <-
  (matchTryAgain -> Just message)
  where
    TryAgainError message =
      RedisClusterError $ RedisTryAgain $ BS8.pack message

pattern CrossSlotError :: String -> RedisClientError
pattern CrossSlotError message <-
  (matchCrossSlot -> Just message)
  where
    CrossSlotError message =
      RedisClusterError $ RedisCrossSlot $ BS8.pack message

pattern RedisCommandError :: ByteString -> RedisClientError
pattern RedisCommandError message = RedisServerError message

pattern MaxRetriesExceeded :: String -> RedisClientError
pattern MaxRetriesExceeded message <-
  (matchRetryExhausted -> Just message)
  where
    MaxRetriesExceeded message =
      RedisClusterError $
        RedisRetryExhausted 0
          (RedisClusterError $ RedisTopologyFailure message)

pattern TopologyError :: String -> RedisClientError
pattern TopologyError message =
  RedisClusterError (RedisTopologyFailure message)

pattern ConnectionError :: String -> RedisClientError
pattern ConnectionError message <-
  (matchTransportFailure -> Just message)
  where
    ConnectionError message =
      RedisTransportError $ toException $ userError message

pattern ConnectionTimeoutError
  :: ConnectionSetupException -> RedisClientError
pattern ConnectionTimeoutError exception <-
  RedisTransportError (fromException -> Just exception)
  where
    ConnectionTimeoutError exception =
      RedisTransportError $ toException exception

pattern ClusterAuthenticationError
  :: ClusterAuthenticationException -> RedisClientError
pattern ClusterAuthenticationError exception <-
  RedisTransportError (fromException -> Just exception)
  where
    ClusterAuthenticationError exception =
      RedisTransportError $ toException exception

pattern ClusterClientClosed :: RedisClientError
pattern ClusterClientClosed = RedisLifecycleError RedisClientClosed

matchMoved :: RedisClientError -> Maybe (Word16, NodeAddress)
matchMoved (RedisClusterError (RedisMoved slot host port)) =
  Just (slot, NodeAddress host port)
matchMoved _ = Nothing

matchAsk :: RedisClientError -> Maybe (Word16, NodeAddress)
matchAsk (RedisClusterError (RedisAsk slot host port)) =
  Just (slot, NodeAddress host port)
matchAsk _ = Nothing

matchClusterDown :: RedisClientError -> Maybe String
matchClusterDown (RedisClusterError (RedisClusterDown message)) =
  Just $ BS8.unpack message
matchClusterDown _ = Nothing

matchTryAgain :: RedisClientError -> Maybe String
matchTryAgain (RedisClusterError (RedisTryAgain message)) =
  Just $ BS8.unpack message
matchTryAgain _ = Nothing

matchCrossSlot :: RedisClientError -> Maybe String
matchCrossSlot (RedisClusterError (RedisCrossSlot message)) =
  Just $ BS8.unpack message
matchCrossSlot _ = Nothing

matchRetryExhausted :: RedisClientError -> Maybe String
matchRetryExhausted
  (RedisClusterError (RedisRetryExhausted retries lastError)) =
    Just $ "Max retries (" ++ show retries
      ++ ") exceeded; last error: " ++ legacyClusterErrorName lastError
matchRetryExhausted _ = Nothing

legacyClusterErrorName :: RedisClientError -> String
legacyClusterErrorName (RedisClusterError (RedisMoved slot host port)) =
  "MovedError " ++ show slot ++ " " ++ show (NodeAddress host port)
legacyClusterErrorName (RedisClusterError (RedisAsk slot host port)) =
  "AskError " ++ show slot ++ " " ++ show (NodeAddress host port)
legacyClusterErrorName (RedisClusterError (RedisTryAgain message)) =
  "TryAgainError " ++ show (BS8.unpack message)
legacyClusterErrorName (RedisClusterError (RedisClusterDown message)) =
  "ClusterDownError " ++ show (BS8.unpack message)
legacyClusterErrorName errorValue = show errorValue

matchTransportFailure :: RedisClientError -> Maybe String
matchTransportFailure (RedisTransportError exception) =
  Just $ show exception
matchTransportFailure _ = Nothing

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
  IO (Either RedisClientError a)
runClusterCommandClient client (ClusterCommandClient action) =
  tryRedisClient $ State.evalStateT action client

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
    (unRedisCommandClient authenticationAction)
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
        State.evalStateT (unRedisCommandClient clusterSlots) clientState

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
  IO (Either RedisClientError ())
refreshTopology client =
  refreshTopologyFromCandidates client [] []

refreshTopologyFromCandidates
  :: (Client client)
  => ClusterClient client
  -> [NodeAddress]
  -> [(Word16, NodeAddress)]
  -> IO (Either RedisClientError ())
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
      return $ Left $ RedisClusterError $
        RedisTopologyFailure "No topology refresh candidates available"
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
              Left err       -> Left $ RedisClusterError $
                RedisTopologyFailure err
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
    refreshResult <- refreshTopology client
    either throwIO pure refreshResult

-- | Classify every Redis error reply returned by a cluster command.
--
-- Prefixes are case-sensitive and must end at the error token boundary.
-- Malformed redirections and unrecognized server errors remain ordinary
-- 'RedisCommandError' values with their full payload preserved.
{-# INLINE classifyClusterReply #-}
classifyClusterReply :: RespData -> Either RedisClientError RespData
classifyClusterReply (RespError msg)
  | Just redirection <- classifyRedirection msg =
      case redirection of
        Left (RedirectionInfo slot host port) ->
          Left $ RedisClusterError $ RedisMoved slot host port
        Right (RedirectionInfo slot host port) ->
          Left $ RedisClusterError $ RedisAsk slot host port
  | hasErrorPrefix "TRYAGAIN" msg =
      Left $ RedisClusterError $ RedisTryAgain msg
  | hasErrorPrefix "CLUSTERDOWN" msg =
      Left $ RedisClusterError $ RedisClusterDown msg
  | hasErrorPrefix "CROSSSLOT" msg =
      Left $ RedisClusterError $ RedisCrossSlot msg
  | otherwise = Left $ RedisServerError msg
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
  IO (Either RedisClientError RespData)
executeOnNode client nodeAddr action connector = do
  result <- tryClusterAction $
    withConnectionBounded
      (clusterConnectionPool client) nodeAddr connector $ \conn -> do
        let clientState = ClientState conn BS8.empty
        runPooledCommand $
          State.evalStateT (unRedisCommandClient action) clientState

  return $ classifyExecutedResult $ result >>= id

classifyExecutedResult
  :: Either RedisClientError RespData
  -> Either RedisClientError RespData
classifyExecutedResult (Left (RedisServerError message)) =
  classifyClusterReply $ RespError message
classifyExecutedResult (Left errorValue) = Left errorValue
classifyExecutedResult (Right response) = classifyClusterReply response

runPooledCommand :: IO a -> IO (Either RedisClientError a)
runPooledCommand action = do
  result <- try action
  case result of
    Right value -> pure $ Right value
    Left (exception :: SomeException) ->
      case fromException exception of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing ->
          case fromException exception of
            Just serverError@(RedisServerError _) ->
              pure $ Left serverError
            Just redisError -> throwIO (redisError :: RedisClientError)
            Nothing         -> throwIO exception

-- | Execute a command that does not target a specific key (e.g., PING, AUTH, FLUSHALL).
-- Routed to an arbitrary master node.
executeKeylessClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  RedisCommandClient client RespData ->
  IO (Either RedisClientError RespData)
executeKeylessClusterCommand =
  executeKeylessClusterCommandUsingDelay threadDelay

-- | Test seam for deterministic keyless retry schedules.
executeKeylessClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  RedisCommandClient client RespData ->
  IO (Either RedisClientError RespData)
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
  IO (Either RedisClientError RespData)
executeKeylessAttempt client action = do
  let connector = clusterConnector client
  topology <- readTVarIO (clusterTopology client)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
  case masterNodes of
    []       -> return $ Left $ RedisClusterError $
      RedisTopologyFailure "No master nodes available"
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
  (RetryRoute -> IO (Either RedisClientError a)) ->
  IO (Either RedisClientError a)
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
  (RetryRoute -> IO (Either RedisClientError a)) ->
  IO (Either RedisClientError a)
withRetryAndRefreshPolicyUsing retryPolicy delayAction
    client maxRetries initialDelay action =
  go 0 initialDelay RouteBySlot
  where
    go attempt delay route
      | attempt >= maxRetries =
          return $ Left $ RedisClusterError $
            RedisRetryExhausted maxRetries
              (RedisClusterError $
                RedisTopologyFailure "retry budget exhausted before an attempt")
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
            Left err@(RedisClusterError (RedisTryAgain _)) ->
              retryAfterDelay err route delay
            Left err@(RedisClusterError (RedisClusterDown _)) -> do
              if attempt + 1 >= maxRetries
                then return $ retryExhausted maxRetries err
                else do
                  refreshResult <- refreshForRoute route
                  case refreshResult of
                    Left closed@(RedisLifecycleError RedisClientClosed) ->
                      return $ Left closed
                    _ -> retryAfterDelay err RouteBySlot delay
            Left err@(RedisClusterError (RedisMoved slot host port))
              | retryPolicy == KeyedRetryPolicy -> do
                  let address = NodeAddress host port
                  atomically $ patchMovedSlot (clusterTopology client) slot address
                  retryImmediately err $ RouteMoved slot address
            Left err@(RedisClusterError (RedisAsk _ host port))
              | retryPolicy == KeyedRetryPolicy ->
                  retryImmediately err $ RouteAsk $ NodeAddress host port
            Left err@(RedisTransportError cause)
              | Just (_ :: ConnectionSetupException) <- fromException cause
              , retryPolicy == KeyedRetryPolicy -> do
                  refreshResult <- case route of
                    RouteMoved _ _ -> refreshForRoute route
                    _              -> return $ Right ()
                  case refreshResult of
                    Left closed@(RedisLifecycleError RedisClientClosed) ->
                      return $ Left closed
                    Left refreshErr@(RedisClusterError (RedisTopologyFailure _)) ->
                      return $ Left refreshErr
                    _ -> retryAfterDelay err RouteBySlot delay
            Left err@(RedisTransportError cause)
              | Just (_ :: ClusterAuthenticationException) <-
                  fromException cause ->
                  return $ Left err
              | retryPolicy == KeyedRetryPolicy -> do
                  refreshResult <- refreshForRoute route
                  case refreshResult of
                    Left closed@(RedisLifecycleError RedisClientClosed) ->
                      return $ Left closed
                    Left refreshErr@(RedisClusterError (RedisTopologyFailure _)) ->
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

retryExhausted :: Int -> RedisClientError -> Either RedisClientError a
retryExhausted maxRetries lastError =
  Left $ RedisClusterError $ RedisRetryExhausted maxRetries lastError

normalizeDelay :: Int -> Int
normalizeDelay = max 0

nextRetryDelay :: Int -> Int
nextRetryDelay delay
  | normalized > maxBound `div` 2 = maxBound
  | otherwise = normalized * 2
  where
    normalized = normalizeDelay delay

tryClusterAction :: IO a -> IO (Either RedisClientError a)
tryClusterAction action = do
  result <- try action
  case result of
    Right value -> return $ Right value
    Left (e :: SomeException) ->
      case fromException e of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing
          | Just redisError <- fromException e ->
              return $ Left (redisError :: RedisClientError)
          | Just ConnectionPoolClosed <- fromException e ->
              return $ Left $ RedisLifecycleError RedisClientClosed
          | Just MultiplexPoolClosed <- fromException e ->
              return $ Left $ RedisLifecycleError RedisClientClosed
          | Just (MultiplexerParseError message) <- fromException e ->
              return $ Left $ RedisProtocolError $
                RedisParseFailure message
          | Just MultiplexerConnectionClosed <- fromException e ->
              return $ Left $ RedisProtocolError RedisConnectionClosed
          | Just (timeoutError :: ConnectionSetupException) <- fromException e ->
              return $ Left $ RedisTransportError $ toException timeoutError
          | Just (authenticationError :: ClusterAuthenticationException) <-
              fromException e ->
              return $ Left $ RedisTransportError $
                toException authenticationError
          | Just (TopologyValidationException err) <- fromException e ->
              return $ Left $ RedisClusterError $ RedisTopologyFailure err
          | otherwise ->
              return $ Left $ RedisTransportError e

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
  ClusterCommandClient client (Either RedisClientError RespData)
executeKeylessCommand action = do
  client <- State.get
  liftIO $ executeKeylessClusterCommand client action

-- | Re-throw an internal typed result for the public runner boundary.
unwrapClusterResult :: (Client client) => Either RedisClientError a -> ClusterCommandClient client a
unwrapClusterResult (Right a)  = pure a
unwrapClusterResult (Left err) = liftIO $ throwIO err

-- | Execute a keyed command and unwrap the result.
-- Routes through the multiplexer pool for pipelined execution.
executeKeyed :: (Client client) => ByteString -> [ByteString] -> ClusterCommandClient client RespData
executeKeyed key cmdArgs = do
  client <- State.get
  result <- liftIO $ executeKeyedClusterCommand client key cmdArgs
  unwrapClusterResult result

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
  -> IO (Either RedisClientError (Maybe RespData))
executeKeylessMaybeAttempt client action = do
  topology <- readTVarIO $ clusterTopology client
  let masters =
        [ node
        | node <- Map.elems $ topologyNodes topology
        , nodeRole node == Master
        ]
  case masters of
    [] -> return $ Left $ RedisClusterError $
      RedisTopologyFailure "No master nodes available"
    node : _ -> do
      result <- tryClusterAction $
        withConnectionBounded
          (clusterConnectionPool client)
          (nodeAddress node)
          (clusterConnector client) $ \conn -> do
            let clientState = ClientState conn BS8.empty
            runPooledCommand $
              State.evalStateT
                (unRedisCommandClient action)
                clientState
      return $ (result >>= id) >>= traverse classifyClusterReply

crossSlotMessage :: String
crossSlotMessage = "CROSSSLOT Keys in request don't hash to the same slot"

ensureSingleSlot :: [ByteString] -> Either ClusterError ByteString
ensureSingleSlot [] = Left $ TopologyError "expected at least one routing key"
ensureSingleSlot (key : remainingKeys)
  | all ((== calculateSlot key) . calculateSlot) remainingKeys = Right key
  | otherwise = Left $ CrossSlotError crossSlotMessage

executeKeylessDescriptor
  :: (Client client, FromResp a)
  => CommandDescriptor
  -> ClusterCommandClient client a
executeKeylessDescriptor descriptor =
  executeKeyless (executeCommandDescriptor descriptor)

executeKeylessMaybeDescriptor
  :: (Client client)
  => CommandDescriptor
  -> ClusterCommandClient client (Maybe RespData)
executeKeylessMaybeDescriptor descriptor =
  executeKeylessMaybe (Just <$> RedisCommandClient.executeCommandDescriptor descriptor)

executeCommandDescriptorCluster
  :: (Client client)
  => CommandDescriptor
  -> ClusterCommandClient client RespData
executeCommandDescriptorCluster descriptor =
  case RedisCommandClient.commandDescriptorRoute descriptor of
    CommandKeyless ->
      executeKeylessCommand (RedisCommandClient.executeCommandDescriptor descriptor)
        >>= unwrapClusterResult
    CommandByKey key ->
      executeKeyed key (RedisCommandClient.commandDescriptorFrame descriptor)
    CommandByKeys keys ->
      case ensureSingleSlot keys of
        Left err -> unwrapClusterResult (Left err)
        Right key ->
          executeKeyed key (RedisCommandClient.commandDescriptorFrame descriptor)
    CommandByMetadata ->
      case classifyCommandFrame (RedisCommandClient.commandDescriptorFrame descriptor) of
        Right FrameKeyless ->
          executeKeylessCommand (RedisCommandClient.executeCommandDescriptor descriptor)
            >>= unwrapClusterResult
        Right (FrameSingleSlot key _) ->
          executeKeyed key (RedisCommandClient.commandDescriptorFrame descriptor)
        Right (FrameCrossSlot _) ->
          unwrapClusterResult (Left $ CrossSlotError crossSlotMessage)
        Left errorValue ->
          liftIO $ throwIO $ RedisProtocolError $
            RedisCommandValidationFailure $ renderCommandGrammarError errorValue

executeCommandDescriptorClusterAs
  :: (Client client, FromResp a)
  => CommandDescriptor
  -> ClusterCommandClient client a
executeCommandDescriptorClusterAs descriptor =
  executeCommandDescriptorCluster descriptor >>= convertResp

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
  IO (Either RedisClientError RespData)
executeKeyedClusterCommand =
  executeKeyedClusterCommandUsingDelay threadDelay

-- | Test seam for deterministic retry schedule and cancellation coverage.
executeKeyedClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  ByteString ->
  [ByteString] ->
  IO (Either RedisClientError RespData)
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
  IO (Either RedisClientError RespData)
executeRawClusterCommand =
  executeRawClusterCommandUsingDelay threadDelay

-- | Deterministic-delay variant of 'executeRawClusterCommand'.
executeRawClusterCommandUsingDelay ::
  (Client client) =>
  (Int -> IO ()) ->
  ClusterClient client ->
  RawClusterRoute ->
  RespData ->
  IO (Either RedisClientError RespData)
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
  IO (Either RedisClientError RespData)
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
  IO (Either RedisClientError RespData)
executeKeylessFrameAttempt client frameBuilder = do
  topology <- readTVarIO $ clusterTopology client
  let masterNodes =
        [ node
        | node <- Map.elems $ topologyNodes topology
        , nodeRole node == Master
        ]
  case masterNodes of
    []       -> return $ Left $ RedisClusterError $
      RedisTopologyFailure "No master nodes available"
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
  IO (Either RedisClientError RespData)
executeOnSlotMux client muxPool slot cmdBuilder = do
  topology <- readTVarIO (clusterTopology client)
  case findNodeAddressForSlot topology slot of
    Nothing -> return $ Left $ RedisClusterError $
      RedisTopologyFailure $ "No node found for slot " ++ show slot
    Just addr -> do
      result <- tryClusterAction $ submitToNode muxPool addr cmdBuilder
      return $ result >>= classifyClusterReply

executeOnNodeDirect
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder
  -> IO (Either RedisClientError RespData)
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
  IO (Either RedisClientError RespData)
executeOnNodeWithAsking _client muxPool addr cmdBuilder = do
  let askingBuilder = encodeCommandBuilder ["ASKING"]
  result <- tryClusterAction $
    submitToNodeWithAsking muxPool addr askingBuilder cmdBuilder
  return $ result >>= classifyClusterReply

instance (Client client) => RedisCommands (ClusterCommandClient client) where
  auth _ _ = liftIO $ throwIO $ RedisLifecycleError $
    RedisUnsupportedOperation $
      toException ClusterRuntimeAuthenticationUnsupported
  ping =
    executeKeylessDescriptor (RedisCommandClient.definedPing RedisCommandClient.redisCommandDefinitions)
  set key value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSet RedisCommandClient.redisCommandDefinitions key value)
  get key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGet RedisCommandClient.redisCommandDefinitions key)
  mget keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedMget RedisCommandClient.redisCommandDefinitions keys)
  setnx key value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSetnx RedisCommandClient.redisCommandDefinitions key value)
  decr key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedDecr RedisCommandClient.redisCommandDefinitions key)
  append key value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedAppend RedisCommandClient.redisCommandDefinitions key value)
  strlen key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedStrlen RedisCommandClient.redisCommandDefinitions key)
  setex key seconds value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSetex RedisCommandClient.redisCommandDefinitions key seconds value)
  incrby key amount =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedIncrby RedisCommandClient.redisCommandDefinitions key amount)
  decrby key amount =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedDecrby RedisCommandClient.redisCommandDefinitions key amount)
  incrbyfloat key amount =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedIncrbyfloat RedisCommandClient.redisCommandDefinitions key amount)
  getdel key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGetdel RedisCommandClient.redisCommandDefinitions key)
  getex key opts =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGetex RedisCommandClient.redisCommandDefinitions key opts)
  psetex key milliseconds value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedPsetex RedisCommandClient.redisCommandDefinitions key milliseconds value)
  bulkSet pairs =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedBulkSet RedisCommandClient.redisCommandDefinitions pairs)
  flushAll =
    executeKeylessDescriptor
      (RedisCommandClient.definedFlushAll RedisCommandClient.redisCommandDefinitions)
  dbsize =
    executeKeylessDescriptor
      (RedisCommandClient.definedDbsize RedisCommandClient.redisCommandDefinitions)
  del keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedDel RedisCommandClient.redisCommandDefinitions keys)
  exists keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedExists RedisCommandClient.redisCommandDefinitions keys)
  incr key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedIncr RedisCommandClient.redisCommandDefinitions key)
  hset key field value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHset RedisCommandClient.redisCommandDefinitions key field value)
  hget key field =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHget RedisCommandClient.redisCommandDefinitions key field)
  hmget key fields =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHmget RedisCommandClient.redisCommandDefinitions key fields)
  hexists key field =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHexists RedisCommandClient.redisCommandDefinitions key field)
  lpush key values =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLpush RedisCommandClient.redisCommandDefinitions key values)
  lrange key start stop =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLrange RedisCommandClient.redisCommandDefinitions key start stop)
  expire key seconds =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedExpire RedisCommandClient.redisCommandDefinitions key seconds)
  ttl key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedTtl RedisCommandClient.redisCommandDefinitions key)
  persist key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedPersist RedisCommandClient.redisCommandDefinitions key)
  keyType key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedKeyType RedisCommandClient.redisCommandDefinitions key)
  rename key newkey =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedRename RedisCommandClient.redisCommandDefinitions key newkey)
  renamenx key newkey =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedRenamenx RedisCommandClient.redisCommandDefinitions key newkey)
  unlink keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedUnlink RedisCommandClient.redisCommandDefinitions keys)
  pfadd key elements =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedPfadd RedisCommandClient.redisCommandDefinitions key elements)
  pfcount keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedPfcount RedisCommandClient.redisCommandDefinitions keys)
  pfmerge destkey sourcekeys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedPfmerge RedisCommandClient.redisCommandDefinitions destkey sourcekeys)
  rpush key values =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedRpush RedisCommandClient.redisCommandDefinitions key values)
  lpop key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLpop RedisCommandClient.redisCommandDefinitions key)
  rpop key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedRpop RedisCommandClient.redisCommandDefinitions key)
  sadd key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSadd RedisCommandClient.redisCommandDefinitions key members)
  smembers key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSmembers RedisCommandClient.redisCommandDefinitions key)
  scard key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedScard RedisCommandClient.redisCommandDefinitions key)
  sismember key member =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSismember RedisCommandClient.redisCommandDefinitions key member)
  srem key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSrem RedisCommandClient.redisCommandDefinitions key members)
  sdiff keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSdiff RedisCommandClient.redisCommandDefinitions keys)
  sinter keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSinter RedisCommandClient.redisCommandDefinitions keys)
  sunion keys =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSunion RedisCommandClient.redisCommandDefinitions keys)
  spop key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSpop RedisCommandClient.redisCommandDefinitions key)
  srandmember key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedSrandmember RedisCommandClient.redisCommandDefinitions key)
  hdel key fields =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHdel RedisCommandClient.redisCommandDefinitions key fields)
  hkeys key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHkeys RedisCommandClient.redisCommandDefinitions key)
  hvals key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHvals RedisCommandClient.redisCommandDefinitions key)
  hgetall key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHgetall RedisCommandClient.redisCommandDefinitions key)
  hlen key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHlen RedisCommandClient.redisCommandDefinitions key)
  hsetnx key field value =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHsetnx RedisCommandClient.redisCommandDefinitions key field value)
  hincrby key field amount =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHincrby RedisCommandClient.redisCommandDefinitions key field amount)
  hincrbyfloat key field amount =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedHincrbyfloat RedisCommandClient.redisCommandDefinitions key field amount)
  llen key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLlen RedisCommandClient.redisCommandDefinitions key)
  lindex key index =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLindex RedisCommandClient.redisCommandDefinitions key index)
  linsert key pos pivot element =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLinsert RedisCommandClient.redisCommandDefinitions key pos pivot element)
  lset key index element =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLset RedisCommandClient.redisCommandDefinitions key index element)
  ltrim key start stop =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLtrim RedisCommandClient.redisCommandDefinitions key start stop)
  lrem key count element =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedLrem RedisCommandClient.redisCommandDefinitions key count element)
  clientSetInfo args =
    executeKeylessDescriptor
      (RedisCommandClient.definedClientSetInfo RedisCommandClient.redisCommandDefinitions args)
  clientReply ON =
    executeKeylessMaybeDescriptor
      (RedisCommandClient.definedClientReplyOn RedisCommandClient.redisCommandDefinitions)
  clientReply val = liftIO $ throwIO $ RedisLifecycleError $
    RedisUnsupportedOperation $ toException $ ClientReplyModeUnsupported val
  zadd key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZadd RedisCommandClient.redisCommandDefinitions key members)
  zrange key start stop withScores =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZrange RedisCommandClient.redisCommandDefinitions key start stop withScores)
  zrem key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZrem RedisCommandClient.redisCommandDefinitions key members)
  zcard key =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZcard RedisCommandClient.redisCommandDefinitions key)
  zscore key member =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZscore RedisCommandClient.redisCommandDefinitions key member)
  zrank key member =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZrank RedisCommandClient.redisCommandDefinitions key member)
  zrevrank key member =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZrevrank RedisCommandClient.redisCommandDefinitions key member)
  zcount key minValue maxValue =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZcount RedisCommandClient.redisCommandDefinitions key minValue maxValue)
  zincrby key increment member =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZincrby RedisCommandClient.redisCommandDefinitions key increment member)
  zrangestore dest src minValue maxValue options =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedZrangestore RedisCommandClient.redisCommandDefinitions dest src minValue maxValue options)
  geoadd key entries =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeoadd RedisCommandClient.redisCommandDefinitions key entries)
  geodist key member1 member2 unit =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeodist RedisCommandClient.redisCommandDefinitions key member1 member2 unit)
  geohash key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeohash RedisCommandClient.redisCommandDefinitions key members)
  geopos key members =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeopos RedisCommandClient.redisCommandDefinitions key members)
  georadius key lon lat radius unit flags =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeoradius RedisCommandClient.redisCommandDefinitions key lon lat radius unit flags)
  georadiusRo key lon lat radius unit flags =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeoradiusRo RedisCommandClient.redisCommandDefinitions key lon lat radius unit flags)
  georadiusByMember key member radius unit flags =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeoradiusByMember RedisCommandClient.redisCommandDefinitions key member radius unit flags)
  georadiusByMemberRo key member radius unit flags =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeoradiusByMemberRo RedisCommandClient.redisCommandDefinitions key member radius unit flags)
  geosearch key fromSpec bySpec options =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeosearch RedisCommandClient.redisCommandDefinitions key fromSpec bySpec options)
  geosearchstore dest src fromSpec bySpec options storeDist =
    executeCommandDescriptorClusterAs
      (RedisCommandClient.definedGeosearchstore RedisCommandClient.redisCommandDefinitions dest src fromSpec bySpec options storeDist)
  clusterSlots =
    executeKeylessDescriptor
      (RedisCommandClient.definedClusterSlots RedisCommandClient.redisCommandDefinitions)
