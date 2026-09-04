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
    PoolConfig (..),
    createPool,
    withConnection,
    closePool,
  )
where

import           Control.Concurrent.MVar  (MVar, modifyMVar, newEmptyMVar,
                                           newMVar, putMVar, takeMVar)
import           Control.Exception        (Exception, SomeException, catch,
                                           mask, throwIO, toException, try)
import           Control.Monad            (forM_)
import           Data.IORef               (IORef, newIORef, readIORef,
                                           writeIORef)
import           Data.Map.Strict          (Map)
import qualified Data.Map.Strict          as Map
import           Data.Typeable            (Typeable)
import           Database.Redis.Client    (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster   (NodeAddress (..))
import           Database.Redis.Connector (Connector)

-- | Exception thrown when a terminally closed connection pool is used.
data ConnectionPoolException = ConnectionPoolClosed
  deriving (Eq, Show, Typeable)

instance Exception ConnectionPoolException

-- | Configuration for the connection pool.
data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int  -- ^ Maximum number of connections kept per node. Callers block when all connections are in use.
  , connectionTimeout     :: Int  -- ^ Connection timeout in seconds (reserved for future use).
  , maxRetries            :: Int  -- ^ Maximum retry attempts for cluster operations.
  , useTLS                :: Bool -- ^ Whether to use TLS connections.
  }
  deriving (Show)

-- | Per-node connection state: available connections, total count, and waiters
data NodePool client = NodePool
  { availableConns :: [client 'Connected]    -- ^ Idle connections ready for checkout
  , totalConns     :: !Int                   -- ^ Total connections created (available + in-use)
  , waitQueue      :: [MVar (Either SomeException (client 'Connected))]
    -- ^ Threads waiting for a connection. Right = success, Left = pool error (retry).
  }

-- | Thread-safe connection pool using MVar for atomic access.
-- Each node has a pool of connections; callers check out exclusive
-- connections and return them after use. When no connections are
-- available and the pool is at capacity, callers block until one
-- is returned.
data ConnectionPool client = ConnectionPool
  { poolConnections :: MVar (Map NodeAddress (NodePool client))
  , poolClosed      :: IORef Bool
  , poolConfig      :: PoolConfig
  }

-- | Create a new empty connection pool.
-- Connections are created lazily when first requested.
createPool :: PoolConfig -> IO (ConnectionPool client)
createPool config = do
  connections <- newMVar Map.empty
  closed <- newIORef False
  return $ ConnectionPool connections closed config

-- | What to do after acquiring the MVar lock
data CheckoutResult client
  = UseExisting (client 'Connected)                      -- ^ Reuse an idle connection
  | CreateNew                                             -- ^ Create a new connection (slot reserved)
  | Wait (MVar (Either SomeException (client 'Connected)))  -- ^ Block until a connection is returned
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
withConnection pool addr connector action = do
  conn <- checkoutConnection pool addr connector
  result <- try (action conn)
  case result of
    Right val -> do
      returnConnection pool addr conn
      return val
    Left (e :: SomeException) -> do
      discardConnection pool addr conn connector
      throwIO e

-- | Check out a connection from the pool. Creates a new one if none available
-- and the max hasn't been reached. Blocks if pool is at capacity.
checkoutConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  IO (client 'Connected)
checkoutConnection pool addr connector = mask $ \restore -> do
  result <- modifyMVar (poolConnections pool) $ \m -> do
    closed <- readIORef (poolClosed pool)
    if closed
      then return (m, PoolIsClosed)
      else do
        let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
        case availableConns nodePool of
          (conn : rest) -> do
            let updated = nodePool { availableConns = rest }
            return (Map.insert addr updated m, UseExisting conn)
          [] ->
            if totalConns nodePool < maxConnectionsPerNode (poolConfig pool)
              then do
                let updated = nodePool { totalConns = totalConns nodePool + 1 }
                return (Map.insert addr updated m, CreateNew)
              else do
                waiter <- newEmptyMVar
                let updated = nodePool { waitQueue = waitQueue nodePool ++ [waiter] }
                return (Map.insert addr updated m, Wait waiter)
  case result of
    PoolIsClosed -> throwIO ConnectionPoolClosed
    UseExisting conn -> return conn
    CreateNew -> do
      -- Create connection outside the MVar lock
      connResult <- try (restore $ connector addr)
      case connResult of
        Right conn -> do
          accepted <- modifyMVar (poolConnections pool) $ \m -> do
            closed <- readIORef (poolClosed pool)
            return (m, not closed)
          if accepted
            then return conn
            else do
              close conn `catch` \(_ :: SomeException) -> return ()
              throwIO ConnectionPoolClosed
        Left (e :: SomeException) -> do
          -- Creation failed — release the reserved slot
          modifyMVar (poolConnections pool) $ \m -> do
            let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
            return (m', ())
          throwIO e
    Wait waiter -> restore (takeMVar waiter) >>= either throwIO return

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
    closeReturned <- modifyMVar (poolConnections pool) $ \m -> do
      closed <- readIORef (poolClosed pool)
      if closed
        then return (m, True)
        else do
          let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
          case waitQueue nodePool of
            (waiter : rest) -> do
              putMVar waiter (Right conn)
              let updated = nodePool { waitQueue = rest }
              return (Map.insert addr updated m, False)
            [] ->
              if length (availableConns nodePool) < maxConnectionsPerNode (poolConfig pool)
                then do
                  let updated = nodePool { availableConns = conn : availableConns nodePool }
                  return (Map.insert addr updated m, False)
                else do
                  let updated = nodePool { totalConns = totalConns nodePool - 1 }
                  return (Map.insert addr updated m, True)
    whenClose closeReturned
  where
    whenClose True  = close conn `catch` \(_ :: SomeException) -> return ()
    whenClose False = return ()

-- | Discard a connection (on error) and wake a waiter or release the slot.
-- If threads are waiting, attempts to create a replacement connection.
-- If replacement creation fails, the waiter receives the error.
discardConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  client 'Connected ->
  Connector client ->
  IO ()
discardConnection pool addr conn connector = do
  close conn `catch` \(_ :: SomeException) -> return ()
  maybeWaiter <- modifyMVar (poolConnections pool) $ \m -> do
    closed <- readIORef (poolClosed pool)
    if closed
      then return (m, Nothing)
      else do
        let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
        case waitQueue nodePool of
          (waiter : rest) -> do
            let updated = nodePool { waitQueue = rest }
            return (Map.insert addr updated m, Just waiter)
          [] -> do
            let updated = nodePool { totalConns = totalConns nodePool - 1 }
            return (Map.insert addr updated m, Nothing)
  case maybeWaiter of
    Nothing -> return ()
    Just waiter -> mask $ \restore -> do
      -- Try to create a replacement connection for the waiter
      connResult <- try (restore $ connector addr)
      case connResult of
        Right newConn -> do
          accepted <- modifyMVar (poolConnections pool) $ \m -> do
            closed <- readIORef (poolClosed pool)
            return (m, not closed)
          if accepted
            then putMVar waiter (Right newConn)
            else do
              close newConn `catch` \(_ :: SomeException) -> return ()
              putMVar waiter (Left $ toException ConnectionPoolClosed)
        Left (e :: SomeException) -> do
          -- Failed — release the reserved slot and notify waiter of the error
          modifyMVar (poolConnections pool) $ \m -> do
            let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
            return (m', ())
          putMVar waiter (Left e)

-- | Close all connections in the pool and wake any blocked waiters.
-- Closure is terminal and idempotent. Later checkouts throw
-- 'ConnectionPoolClosed' rather than creating a new connection. Exceptions
-- during transport close are caught and ignored.
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool =
  do
    nodePools <- modifyMVar (poolConnections pool) $ \m -> do
      alreadyClosed <- readIORef (poolClosed pool)
      if alreadyClosed
        then return (m, [])
        else do
          writeIORef (poolClosed pool) True
          return (Map.empty, Map.elems m)
    let closedError = toException ConnectionPoolClosed
    forM_ nodePools $ \nodePool -> do
      forM_ (availableConns nodePool) $ \conn ->
        close conn `catch` \(_ :: SomeException) -> return ()
      forM_ (waitQueue nodePool) $ \waiter ->
        putMVar waiter (Left closedError)
