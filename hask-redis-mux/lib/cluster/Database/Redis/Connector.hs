{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE RankNTypes #-}

-- | Connector factories for creating Redis connections.
--
-- The 'Connector' type alias represents a function that creates a connected
-- client for a given 'NodeAddress'. Connector values are passed to
-- 'ClusterCommandClient.createClusterClient' and related functions.
--
-- @
-- import Redis
--
-- main :: IO ()
-- main = do
--   -- Standalone plaintext
--   conn <- connectPlaintext "localhost" 6379
--   ...
--
--   -- Cluster with TLS
--   let connector = clusterTLSConnector "redis.example.com"
--   client <- createClusterClient config connector
--   ...
-- @
--
-- @since 0.1.0.0
module Database.Redis.Connector
  ( -- * Connector type
    Connector
  , ConnectionPhase (..)
  , ConnectionSupervisor (..)
  , ConnectionSetupException (..)
  , withConnectionTimeout
  , withConnectionTimeoutPhased
  , withConnectionTimeoutSupervised
    -- * Standalone connections
  , connectPlaintext
  , connectPlaintextWithTimeout
  , connectTLS
  , connectTLSWithTimeout
    -- * Cluster connector factories
  , clusterPlaintextConnector
  , clusterPlaintextConnectorWithTimeout
  , clusterTLSConnector
  , clusterTLSConnectorWithTimeout
  ) where

import           Control.Concurrent     (ThreadId, forkIOWithUnmask, throwTo)
import           Control.Concurrent.STM (TVar, atomically, check, newTVarIO,
                                         orElse, readTVar, registerDelay, retry,
                                         writeTVar)
import           Control.Exception      (Exception, SomeException, mask,
                                         onException, throwIO, try)
import           Control.Monad          (void)
import           Data.IORef             (atomicModifyIORef', newIORef)
import           Data.Maybe             (isNothing)
import           Data.Typeable          (Typeable)
import           Database.Redis.Client  (CleanupRegistrar,
                                         Client (abort, connect),
                                         ConnectionPhase (..),
                                         ConnectionStatus (..), PhaseSetter,
                                         PlainTextClient (NotConnectedPlainTextClient),
                                         TLSClient (NotConnectedTLSClient, NotConnectedTLSClientWithHostname),
                                         connectPlaintextWithCleanup,
                                         connectTLSWithCleanup)
import           Database.Redis.Cluster (NodeAddress (..))

-- | A function that creates a connected client for a given node address.
-- Used throughout the cluster layer to establish connections on demand.
type Connector client = NodeAddress -> IO (client 'Connected)

-- | Hooks exposed to a production connector running under a deadline.
--
-- Register a connected transport before potentially blocking authentication.
-- If the deadline expires in that phase, the supervisor atomically claims and
-- aborts that transport while independently requesting worker cancellation.
data ConnectionSupervisor client = ConnectionSupervisor
  { setConnectionPhase         :: PhaseSetter
  , registerSetupCleanup       :: CleanupRegistrar
  , registerConnectedTransport :: client 'Connected -> IO (IO ())
  }

-- | A connection setup attempt exceeded its configured wall-clock deadline.
-- The endpoint and transport phase are retained without including connector
-- arguments or credentials.
data ConnectionSetupException = ConnectionSetupTimeout
  { connectionTimeoutPhase    :: !ConnectionPhase
  , connectionTimeoutEndpoint :: !NodeAddress
  , connectionTimeoutSeconds  :: !Int
  }
  deriving (Eq, Show, Typeable)

instance Exception ConnectionSetupException

-- | Bound one complete connector action by a wall-clock deadline in seconds.
-- For the built-in plaintext connector this covers DNS, socket setup, and TCP
-- connect. For TLS it additionally covers certificate-store/context setup and
-- the TLS handshake.
withConnectionTimeout
  :: (Client client)
  => Int
  -> ConnectionPhase
  -> Connector client
  -> Connector client
withConnectionTimeout seconds phase connector =
  withConnectionTimeoutPhased seconds phase (const connector)

-- | Supervise a connector in a worker while it reports the active production
-- phase. Caller return at the deadline does not depend on asynchronous
-- interruption of that worker. A stop request is still sent so interruptible
-- setup unwinds and closes its owned resources promptly; any connection
-- returned after the deadline is abortively closed instead of escaping.
withConnectionTimeoutPhased
  :: (Client client)
  => Int
  -> ConnectionPhase
  -> (PhaseSetter -> Connector client)
  -> Connector client
withConnectionTimeoutPhased seconds initialPhase phasedConnector addr
  = withConnectionTimeoutSupervised seconds initialPhase
      (\supervisor ->
        phasedConnector (setConnectionPhase supervisor)) addr

-- | Supervise setup with both phase reporting and active ownership tracking.
-- The latter is required for authenticated setup: once a transport has been
-- created, register it before AUTH so expiry can abort the socket immediately.
withConnectionTimeoutSupervised
  :: (Client client)
  => Int
  -> ConnectionPhase
  -> (ConnectionSupervisor client -> Connector client)
  -> Connector client
withConnectionTimeoutSupervised seconds initialPhase supervisedConnector addr
  | seconds <= 0 =
      throwIO $ ConnectionSetupTimeout initialPhase addr seconds
  | otherwise = mask $ \restore -> do
      state <- newTVarIO $ AttemptRunning Nothing
      phase <- newTVarIO initialPhase
      worker <- forkIOWithUnmask $ \unmask -> do
        let supervisor = ConnectionSupervisor
              { setConnectionPhase = atomically . writeTVar phase
              , registerSetupCleanup = registerAttemptCleanup state
              , registerConnectedTransport =
                  registerAttemptTransport state
              }
        outcome <- try $ unmask $ supervisedConnector supervisor addr
        disposition <- atomically $ do
          current <- readTVar state
          case current of
            AttemptRunning _ -> do
              writeTVar state $ AttemptFinished outcome
              return $ AttemptDelivered $ case outcome of
                Left _  -> attemptCleanup current
                Right _ -> Nothing
            AttemptExpired discardLate ->
              return $ if discardLate
                then AttemptDiscarded
                else AttemptAlreadyCleaned
            AttemptFinished _ -> return AttemptDiscarded
        case (disposition, outcome) of
          (AttemptDiscarded, Right conn) -> abort conn
          (AttemptDelivered cleanup, _)  ->
            mapM_ requestCleanup cleanup
          _ -> return ()
      timer <- registerDelay $ secondsToMicroseconds seconds
      outcome <- restore (awaitAttempt state phase timer)
        `onException` abandonAttempt state worker
      case outcome of
        AttemptCompleted (Right conn) -> return conn
        AttemptCompleted (Left err)   -> throwIO err
        AttemptDeadline expiredPhase owned -> do
          mapM_ requestCleanup owned
          requestWorkerStop worker
          throwIO $ ConnectionSetupTimeout expiredPhase addr seconds

data AttemptState client
  = AttemptRunning (Maybe (IO ()))
  | AttemptFinished (Either SomeException (client 'Connected))
  | AttemptExpired Bool

data AttemptOutcome client
  = AttemptCompleted (Either SomeException (client 'Connected))
  | AttemptDeadline ConnectionPhase (Maybe (IO ()))

data AttemptDisposition
  = AttemptDelivered (Maybe (IO ()))
  | AttemptDiscarded
  | AttemptAlreadyCleaned

attemptCleanup :: AttemptState client -> Maybe (IO ())
attemptCleanup (AttemptRunning cleanup) = cleanup
attemptCleanup _                        = Nothing

data SetupWorkerCancelled = SetupWorkerCancelled
  deriving (Show, Typeable)

instance Exception SetupWorkerCancelled

awaitAttempt
  :: TVar (AttemptState client)
  -> TVar ConnectionPhase
  -> TVar Bool
  -> IO (AttemptOutcome client)
awaitAttempt state phase timer = atomically $
  awaitFinished `orElse` awaitDeadline
  where
    awaitFinished = do
      current <- readTVar state
      case current of
        AttemptFinished outcome -> return $ AttemptCompleted outcome
        _                       -> retry
    awaitDeadline = do
      expired <- readTVar timer
      check expired
      currentPhase <- readTVar phase
      current <- readTVar state
      case current of
        AttemptRunning owned -> do
          writeTVar state $ AttemptExpired $ isNothing owned
          return $ AttemptDeadline currentPhase owned
        _ -> retry

abandonAttempt
  :: (Client client)
  => TVar (AttemptState client)
  -> ThreadId
  -> IO ()
abandonAttempt state worker = do
  cleanup <- atomically $ do
    current <- readTVar state
    let (discardLate, transport) = case current of
          AttemptRunning currentOwned ->
            (isNothing currentOwned, currentOwned)
          AttemptFinished (Right conn) -> (False, Just $ abort conn)
          _                            -> (True, Nothing)
    writeTVar state $ AttemptExpired discardLate
    return transport
  mapM_ requestCleanup cleanup
  requestWorkerStop worker

registerAttemptTransport
  :: (Client client)
  => TVar (AttemptState client)
  -> client 'Connected
  -> IO (IO ())
registerAttemptTransport state conn = do
  registerAttemptCleanup state $ abort conn

registerAttemptCleanup
  :: TVar (AttemptState client)
  -> IO ()
  -> IO (IO ())
registerAttemptCleanup state cleanup = do
  finalized <- newIORef False
  let cleanupOnce = do
        shouldRun <- atomicModifyIORef' finalized $ \done ->
          (True, not done)
        if shouldRun then cleanup else return ()
  expired <- atomically $ do
    current <- readTVar state
    case current of
      AttemptRunning _ -> do
        writeTVar state $ AttemptRunning $ Just cleanupOnce
        return False
      AttemptExpired _ -> do
        writeTVar state $ AttemptExpired False
        return True
      AttemptFinished _ -> return True
  if expired
    then do
      requestCleanup cleanupOnce
      throwIO SetupWorkerCancelled
    else return cleanupOnce

requestWorkerStop :: ThreadId -> IO ()
requestWorkerStop worker = void $ forkIOWithUnmask $ \_ ->
  throwTo worker SetupWorkerCancelled

requestCleanup :: IO () -> IO ()
requestCleanup cleanup = void $ forkIOWithUnmask $ \unmask ->
  void (try (unmask cleanup) :: IO (Either SomeException ()))

secondsToMicroseconds :: Int -> Int
secondsToMicroseconds seconds =
  fromInteger $ min (toInteger (maxBound :: Int)) (toInteger seconds * 1000000)

-- | Connect a plaintext client to a specific host and port.
--
-- @
-- conn <- connectPlaintext "localhost" 6379
-- @
connectPlaintext :: String -> Int -> IO (PlainTextClient 'Connected)
connectPlaintext host port =
  connect $ NotConnectedPlainTextClient host (Just port)

-- | Deadline-safe plaintext helper. Prefer this over 'connectPlaintext' when
-- calling the connector directly outside a configured pool.
connectPlaintextWithTimeout
  :: Int
  -> String
  -> Int
  -> IO (PlainTextClient 'Connected)
connectPlaintextWithTimeout seconds host port =
  withConnectionTimeoutSupervised seconds DNSResolution
    (\supervisor _ ->
      connectPlaintextWithCleanup
        (setConnectionPhase supervisor)
        (registerSetupCleanup supervisor)
        host
        (Just port))
    (NodeAddress host port)

-- | Connect a TLS client to a specific host and port.
--
-- @
-- conn <- connectTLS "redis.example.com" 6380
-- @
connectTLS :: String -> Int -> IO (TLSClient 'Connected)
connectTLS host port =
  connect $ NotConnectedTLSClient host (Just port)

-- | Deadline-safe TLS helper. Prefer this over 'connectTLS' when calling the
-- connector directly outside a configured pool.
connectTLSWithTimeout
  :: Int
  -> String
  -> Int
  -> IO (TLSClient 'Connected)
connectTLSWithTimeout seconds host port =
  withConnectionTimeoutSupervised seconds DNSResolution
    (\supervisor _ ->
      connectTLSWithCleanup
        (setConnectionPhase supervisor)
        (registerSetupCleanup supervisor)
        host host (Just port))
    (NodeAddress host port)

-- | Create a cluster connector for plaintext connections.
-- Each cluster node will be connected to using its advertised address.
--
-- @
-- let connector = clusterPlaintextConnector
-- client <- createClusterClient config connector
-- @
clusterPlaintextConnector :: Connector PlainTextClient
clusterPlaintextConnector addr =
  connect $ NotConnectedPlainTextClient (nodeHost addr) (Just $ nodePort addr)

clusterPlaintextConnectorWithTimeout
  :: Int
  -> Connector PlainTextClient
clusterPlaintextConnectorWithTimeout seconds =
  withConnectionTimeoutSupervised seconds DNSResolution $ \supervisor addr ->
    connectPlaintextWithCleanup
      (setConnectionPhase supervisor)
      (registerSetupCleanup supervisor)
      (nodeHost addr)
      (Just $ nodePort addr)

-- | Create a cluster connector for TLS connections.
-- The @certHostname@ is used for TLS certificate validation, while each
-- node's advertised address is used for the network connection. This is
-- needed because @CLUSTER SLOTS@ often returns IP addresses that don't
-- match the TLS certificate's hostname.
--
-- @
-- let connector = clusterTLSConnector "redis.example.com"
-- client <- createClusterClient config connector
-- @
clusterTLSConnector :: String -> Connector TLSClient
clusterTLSConnector certHostname addr =
  connect $ NotConnectedTLSClientWithHostname certHostname (nodeHost addr) (Just $ nodePort addr)

clusterTLSConnectorWithTimeout
  :: Int
  -> String
  -> Connector TLSClient
clusterTLSConnectorWithTimeout seconds certHostname =
  withConnectionTimeoutSupervised seconds DNSResolution $ \supervisor addr ->
    connectTLSWithCleanup
      (setConnectionPhase supervisor)
      (registerSetupCleanup supervisor)
      certHostname
      (nodeHost addr)
      (Just $ nodePort addr)
