{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE RankNTypes #-}

-- | Thread-safe connection pool for managing Redis connections.
--
-- Connections are created lazily and managed per-node. Each call to
-- 'withConnection' checks out an exclusive connection for the caller,
-- preventing RESP protocol interleaving between threads. Connections
-- are returned to the pool after use, or discarded if an error occurred.
--
-- When the pool is at capacity, callers block until a connection becomes
-- available rather than creating unbounded overflow connections.
--
-- @since 0.1.0.0
module Database.Redis.Cluster.ConnectionPool
  ( ConnectionPool (..),
    ConnectionPoolException (..),
    ConnectionPoolStats (..),
    PoolConfig (..),
    createPool,
    withConnection,
    withConnectionBounded,
    getConnectionPoolStats,
    closePool,
  )
where

import           Control.Concurrent       (forkIOWithUnmask)
import           Control.Concurrent.MVar  (MVar, modifyMVarMasked, newEmptyMVar,
                                           newMVar, putMVar, readMVar, takeMVar,
                                           withMVar)
import           Control.Exception        (Exception, SomeException, mask,
                                           mask_, onException, throwIO,
                                           toException, try,
                                           uninterruptibleMask_)
import           Control.Monad            (forM_)
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef, writeIORef)
import           Data.Map.Strict          (Map)
import qualified Data.Map.Strict          as Map
import           Data.Typeable            (Typeable)
import           Database.Redis.Client    (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster   (NodeAddress (..))
import           Database.Redis.Connector (ConnectionPhase (..), Connector,
                                           withConnectionTimeout)

-- | Exception thrown when a terminally closed connection pool is used.
data ConnectionPoolException = ConnectionPoolClosed
  deriving (Eq, Show, Typeable)

instance Exception ConnectionPoolException

-- | A point-in-time view of one node's logical pool accounting.
data ConnectionPoolStats = ConnectionPoolStats
  { statsTotalConnections     :: !Int
  , statsAvailableConnections :: !Int
  , statsWaitingCallers       :: !Int
  }
  deriving (Eq, Show)

-- | Configuration for the connection pool.
data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int  -- ^ Maximum number of connections kept per node. Callers block when all connections are in use.
  , connectionTimeout     :: Int  -- ^ Per-attempt setup deadline in seconds. Covers DNS, TCP connect, and TLS context/handshake when enabled.
  , maxRetries            :: Int  -- ^ Maximum retry attempts for cluster operations.
  , useTLS                :: Bool -- ^ Whether to use TLS connections.
  }
  deriving (Show)

-- | Per-node connection state: available connections, total count, and waiters
data NodePool client = NodePool
  { availableConns :: [client 'Connected]    -- ^ Idle connections ready for checkout
  , availableCount :: !Int                   -- ^ Cached idle count; avoids a return-path traversal
  , totalConns     :: !Int                   -- ^ Total connections created (available + in-use)
  , waitQueue      :: !(WaitQueue (Waiter client))
  , nodeClosed     :: !Bool
  }

-- | Amortized O(1) FIFO with a cached size. Cancellation is the uncommon path
-- and filters both lists, while enqueue and direct handoff avoid Seq overhead.
data WaitQueue a = WaitQueue ![a] ![a] !Int

type Waiter client = MVar (WaiterResult client)

data WaiterResult client
  = WaiterConnection !(client 'Connected)
  | WaiterCreate
  | WaiterFailure !SomeException

-- | Thread-safe connection pool using MVar for atomic access.
-- Each node has a pool of connections; callers check out exclusive
-- connections and return them after use. When no connections are
-- available and the pool is at capacity, callers block until one
-- is returned.
data ConnectionPool client = ConnectionPool
  { poolConnections  :: IORef (Map NodeAddress (MVar (NodePool client)))
  , poolRegistryLock :: MVar ()
  , poolClosed       :: IORef Bool
  , poolConfig       :: PoolConfig
  }

-- | Create a new empty connection pool.
-- Connections are created lazily when first requested.
createPool :: PoolConfig -> IO (ConnectionPool client)
createPool config = do
  connections <- newIORef Map.empty
  registryLock <- newMVar ()
  closed <- newIORef False
  return $ ConnectionPool connections registryLock closed config

-- | What to do after acquiring the MVar lock
data CheckoutResult client
  = UseExisting (client 'Connected)                      -- ^ Reuse an idle connection
  | CreateNew                                             -- ^ Create a new connection (slot reserved)
  | Wait !(Waiter client)
  | PoolIsClosed

-- | Check out a connection, run an action, and return the connection to the pool.
-- If the action throws an exception, the connection is discarded (not returned)
-- since its RESP parse state may be corrupted. A fresh connection will be created
-- on the next checkout for that node.
withConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  (client 'Connected -> IO a) ->
  IO a
withConnection pool addr connector action = mask $ \restore -> do
  conn <- checkoutConnection False pool addr connector restore
  result <- restore (action conn)
    `onException` discardConnection pool addr conn
  returnConnection pool addr conn
  return result
{-# INLINE withConnection #-}

-- | Use a connector that already enforces the pool's complete setup deadline.
-- This avoids nesting a coarse pool timeout around a phase-aware connector.
withConnectionBounded ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  (client 'Connected -> IO a) ->
  IO a
withConnectionBounded pool addr connector action = mask $ \restore -> do
  conn <- checkoutConnection True pool addr connector restore
  result <- restore (action conn)
    `onException` discardConnection pool addr conn
  returnConnection pool addr conn
  return result
{-# INLINE withConnectionBounded #-}

-- | Check out a connection from the pool. Creates a new one if none available
-- and the max hasn't been reached. Blocks if pool is at capacity.
checkoutConnection ::
  (Client client) =>
  Bool ->
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  (forall a. IO a -> IO a) ->
  IO (client 'Connected)
checkoutConnection connectorIsBounded pool addr connector restore = checkout
  where
  checkout = do
    nodeState <- getOrCreateNodePool pool addr
    result <- modifyNodePool nodeState $ \nodePool -> do
      if nodeClosed nodePool
        then return (nodePool, PoolIsClosed)
        else do
          case availableConns nodePool of
            (conn : rest) -> do
              let updated = nodePool
                    { availableConns = rest
                    , availableCount = availableCount nodePool - 1
                    }
              return (updated, UseExisting conn)
            [] ->
              if totalConns nodePool < maxConnectionsPerNode (poolConfig pool)
                then do
                  let updated = nodePool { totalConns = totalConns nodePool + 1 }
                  return (updated, CreateNew)
                else do
                  waiter <- newEmptyMVar
                  let updated = nodePool
                        { waitQueue = enqueueWaiter waiter (waitQueue nodePool) }
                  return (updated, Wait waiter)
    case result of
      PoolIsClosed -> throwIO ConnectionPoolClosed
      UseExisting conn -> return conn
      CreateNew -> connectReserved nodeState
      Wait waiter -> do
        wakeup <- takeMVar waiter
          `onException` cancelWaiter pool addr waiter
        case wakeup of
          WaiterConnection conn -> return conn
          WaiterCreate          -> connectReserved nodeState
          WaiterFailure e       -> throwIO e

  connectReserved nodeState = do
    open <- nodePoolIsOpen nodeState
    if not open
      then throwIO ConnectionPoolClosed
      else do
        let phase =
              if useTLS (poolConfig pool)
                then TLSConnectionSetup
                else PlaintextConnectionSetup
            boundedConnector
              | connectorIsBounded = connector
              | otherwise =
                  withConnectionTimeout
                    (connectionTimeout $ poolConfig pool) phase connector
        connResult <- try (restore $ boundedConnector addr)
        case connResult of
          Right conn -> do
            accepted <- nodePoolIsOpen nodeState
            if accepted
              then return conn
              else do
                safeClose conn
                throwIO ConnectionPoolClosed
          Left (e :: SomeException) -> do
            releaseReservation pool addr
            throwIO e
{-# INLINE checkoutConnection #-}

-- | Return a connection to the pool for reuse.
-- If threads are waiting, hand the connection directly to the next waiter.
returnConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  client 'Connected ->
  IO ()
returnConnection pool addr conn =
  do
    let transition = returnToNode pool addr conn
    closeReturned <- transition `onException` do
      closeAfterCancellation <-
        uninterruptibleMask_ $ returnToNode pool addr conn
      if closeAfterCancellation then safeClose conn else return ()
    if closeReturned then safeClose conn else return ()
{-# INLINE returnConnection #-}

returnTransition
  :: ConnectionPool client
  -> client 'Connected
  -> NodePool client
  -> IO (NodePool client, Bool)
returnTransition pool conn nodePool =
  if nodeClosed nodePool
    then return (nodePool, True)
    else do
      case dequeueWaiter (waitQueue nodePool) of
        Just (waiter, rest) -> do
          putMVar waiter (WaiterConnection conn)
          let updated = nodePool { waitQueue = rest }
          return (updated, False)
        Nothing ->
          if availableCount nodePool < maxConnectionsPerNode (poolConfig pool)
            then do
              let updated = nodePool
                    { availableConns = conn : availableConns nodePool
                    , availableCount = availableCount nodePool + 1
                    }
              return (updated, False)
            else do
              let updated = nodePool { totalConns = totalConns nodePool - 1 }
              return (updated, True)
{-# INLINE returnTransition #-}

-- | Discard a connection (on error) and wake a waiter or release the slot.
-- If a thread is waiting, its reservation is transferred directly so it can
-- create the replacement without tying slow connector work to this cleanup.
discardConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  client 'Connected ->
  IO ()
discardConnection pool addr conn = do
  releaseReservation pool addr
  safeClose conn

-- | Read logical accounting for a single node. At quiescence,
-- @statsTotalConnections == statsAvailableConnections@ and
-- @statsWaitingCallers == 0@.
getConnectionPoolStats :: ConnectionPool client -> NodeAddress -> IO ConnectionPoolStats
getConnectionPoolStats pool addr = do
  nodes <- readIORef (poolConnections pool)
  case Map.lookup addr nodes of
    Nothing -> return $ ConnectionPoolStats 0 0 0
    Just nodeState ->
      withMVar nodeState $ \nodePool ->
        return $ ConnectionPoolStats
          (totalConns nodePool)
          (availableCount nodePool)
          (waitQueueLength $ waitQueue nodePool)

-- | Close all connections in the pool and wake any blocked waiters.
-- Closure is terminal and idempotent. Later checkouts throw
-- 'ConnectionPoolClosed' rather than creating a new connection. Exceptions
-- during transport close are caught and ignored.
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool = mask_ $ do
    nodeStates <- uninterruptibleMask_ $
      modifyMVarMasked (poolRegistryLock pool) $ \lock -> do
      alreadyClosed <- readIORef (poolClosed pool)
      if alreadyClosed
        then return (lock, [])
        else do
          writeIORef (poolClosed pool) True
          nodes <- readIORef (poolConnections pool)
          writeIORef (poolConnections pool) Map.empty
          return (lock, Map.elems nodes)
    nodePools <- mapM closeNodePool nodeStates
    closeDone <- mapM startClose
      [conn | nodePool <- nodePools, conn <- availableConns nodePool]
    mapM_ readMVar closeDone

emptyNodePool :: NodePool client
emptyNodePool = NodePool [] 0 0 emptyWaitQueue False

modifyNodePool
  :: MVar (NodePool client)
  -> (NodePool client -> IO (NodePool client, a))
  -> IO a
modifyNodePool nodeState action =
  modifyMVarMasked nodeState action
{-# INLINE modifyNodePool #-}

nodePoolIsOpen :: MVar (NodePool client) -> IO Bool
nodePoolIsOpen nodeState =
  uninterruptibleMask_ $ withMVar nodeState (return . not . nodeClosed)

releaseReservation :: ConnectionPool client -> NodeAddress -> IO ()
releaseReservation pool addr = do
  nodeState <- lookupNodePool pool addr
  forM_ nodeState $ \state ->
    uninterruptibleMask_ $ modifyNodePool state $ \nodePool -> do
    if nodeClosed nodePool
      then return (nodePool, ())
      else case dequeueWaiter (waitQueue nodePool) of
        Just (waiter, rest) -> do
          putMVar waiter WaiterCreate
          let updated = nodePool { waitQueue = rest }
          return (updated, ())
        Nothing -> do
          let updated = nodePool
                { totalConns = max 0 (totalConns nodePool - 1) }
          return (updated, ())

cancelWaiter
  :: (Client client)
  => ConnectionPool client
  -> NodeAddress
  -> Waiter client
  -> IO ()
cancelWaiter pool addr waiter = do
  nodeState <- lookupNodePool pool addr
  removed <- case nodeState of
    Nothing -> return False
    Just state -> uninterruptibleMask_ $ modifyNodePool state $ \nodePool -> do
        let (wasRemoved, remaining) = removeWaiter waiter (waitQueue nodePool)
            updated = nodePool { waitQueue = remaining }
        return (updated, wasRemoved)
  if removed
    then return ()
    else do
      handedOff <- uninterruptibleMask_ $ takeMVar waiter
      case handedOff of
        WaiterConnection conn -> returnConnection pool addr conn
        WaiterCreate          -> releaseReservation pool addr
        WaiterFailure _       -> return ()

safeClose :: (Client client) => client 'Connected -> IO ()
safeClose conn = do
  done <- startClose conn
  readMVar done

startClose :: (Client client) => client 'Connected -> IO (MVar ())
startClose conn = do
  done <- newEmptyMVar
  _ <- forkIOWithUnmask $ \unmask ->
    try (unmask $ close conn) >>= \(_ :: Either SomeException ()) ->
      putMVar done ()
  return done

getOrCreateNodePool
  :: ConnectionPool client -> NodeAddress -> IO (MVar (NodePool client))
getOrCreateNodePool pool addr = do
  nodes <- readIORef (poolConnections pool)
  case Map.lookup addr nodes of
    Just nodeState -> return nodeState
    Nothing -> modifyMVarMasked (poolRegistryLock pool) $ \lock -> do
      closed <- readIORef (poolClosed pool)
      if closed
        then throwIO ConnectionPoolClosed
        else do
          currentNodes <- readIORef (poolConnections pool)
          case Map.lookup addr currentNodes of
            Just nodeState -> return (lock, nodeState)
            Nothing -> do
              nodeState <- newMVar emptyNodePool
              atomicModifyIORef' (poolConnections pool) $ \existing ->
                (Map.insert addr nodeState existing, ())
              return (lock, nodeState)

lookupNodePool
  :: ConnectionPool client -> NodeAddress -> IO (Maybe (MVar (NodePool client)))
lookupNodePool pool addr = Map.lookup addr <$> readIORef (poolConnections pool)

returnToNode
  :: ConnectionPool client -> NodeAddress -> client 'Connected -> IO Bool
returnToNode pool addr conn = do
  nodeState <- lookupNodePool pool addr
  case nodeState of
    Nothing    -> return True
    Just state -> modifyNodePool state $ returnTransition pool conn

closeNodePool :: MVar (NodePool client) -> IO (NodePool client)
closeNodePool nodeState =
  uninterruptibleMask_ $ modifyNodePool nodeState $ \nodePool -> do
    let closedError = toException ConnectionPoolClosed
    forM_ (waitQueueToList $ waitQueue nodePool) $ \waiter ->
      putMVar waiter (WaiterFailure closedError)
    let closedNodePool = nodePool
          { availableConns = []
          , availableCount = 0
          , waitQueue = emptyWaitQueue
          , nodeClosed = True
          }
    return (closedNodePool, nodePool)

emptyWaitQueue :: WaitQueue a
emptyWaitQueue = WaitQueue [] [] 0

enqueueWaiter :: a -> WaitQueue a -> WaitQueue a
enqueueWaiter waiter (WaitQueue front rear count) =
  WaitQueue front (waiter : rear) (count + 1)
{-# INLINE enqueueWaiter #-}

dequeueWaiter :: WaitQueue a -> Maybe (a, WaitQueue a)
dequeueWaiter (WaitQueue (waiter : front) rear count) =
  Just (waiter, WaitQueue front rear (count - 1))
dequeueWaiter (WaitQueue [] rear count) =
  case reverse rear of
    []                -> Nothing
    waiter : newFront -> Just (waiter, WaitQueue newFront [] (count - 1))
{-# INLINE dequeueWaiter #-}

removeWaiter :: (Eq a) => a -> WaitQueue a -> (Bool, WaitQueue a)
removeWaiter target (WaitQueue front rear count) =
  let remainingFront = filter (/= target) front
      remainingRear = filter (/= target) rear
      removedCount =
        (length front - length remainingFront)
          + (length rear - length remainingRear)
  in ( removedCount /= 0
     , WaitQueue remainingFront remainingRear (count - removedCount)
     )

waitQueueLength :: WaitQueue a -> Int
waitQueueLength (WaitQueue _ _ count) = count
{-# INLINE waitQueueLength #-}

waitQueueToList :: WaitQueue a -> [a]
waitQueueToList (WaitQueue front rear _) = front <> reverse rear
