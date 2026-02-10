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
module ConnectionPool
  ( ConnectionPool (..),
    PoolConfig (..),
    createPool,
    withConnection,
    getOrCreateConnection,
    closePool,
  )
where

import           Client                 (Client (..), ConnectionStatus (..))
import           Cluster                (NodeAddress (..))
import           Connector              (Connector)
import           Control.Concurrent.MVar (MVar, newMVar, newEmptyMVar,
                                          modifyMVar, putMVar, takeMVar)
import           Control.Exception      (SomeException, catch, throwIO, try,
                                          toException)
import           Control.Monad          (forM_)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map

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
  , poolConfig      :: PoolConfig
  }

-- | Create a new empty connection pool.
-- Connections are created lazily when first requested.
createPool :: PoolConfig -> IO (ConnectionPool client)
createPool config = do
  connections <- newMVar Map.empty
  return $ ConnectionPool connections config

-- | What to do after acquiring the MVar lock
data CheckoutResult client
  = UseExisting (client 'Connected)                      -- ^ Reuse an idle connection
  | CreateNew                                             -- ^ Create a new connection (slot reserved)
  | Wait (MVar (Either SomeException (client 'Connected)))  -- ^ Block until a connection is returned

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
checkoutConnection pool addr connector = do
  result <- modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
    case availableConns nodePool of
      (conn : rest) -> do
        let updated = nodePool { availableConns = rest }
        return (Map.insert addr updated m, UseExisting conn)
      [] ->
        if totalConns nodePool < maxConnectionsPerNode (poolConfig pool)
          then do
            -- Reserve a slot, create connection outside the lock
            let updated = nodePool { totalConns = totalConns nodePool + 1 }
            return (Map.insert addr updated m, CreateNew)
          else do
            -- At capacity — enqueue a waiter
            waiter <- newEmptyMVar
            let updated = nodePool { waitQueue = waitQueue nodePool ++ [waiter] }
            return (Map.insert addr updated m, Wait waiter)
  case result of
    UseExisting conn -> return conn
    CreateNew -> do
      -- Create connection outside the MVar lock
      connResult <- try (connector addr)
      case connResult of
        Right conn -> return conn
        Left (e :: SomeException) -> do
          -- Creation failed — release the reserved slot
          modifyMVar (poolConnections pool) $ \m -> do
            let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
            return (m', ())
          throwIO e
    Wait waiter -> takeMVar waiter >>= either throwIO return

-- | Return a connection to the pool for reuse.
-- If threads are waiting, hand the connection directly to the next waiter.
returnConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  client 'Connected ->
  IO ()
returnConnection pool addr conn =
  modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
    case waitQueue nodePool of
      (waiter : rest) -> do
        -- Hand connection directly to a waiting thread
        putMVar waiter (Right conn)
        let updated = nodePool { waitQueue = rest }
        return (Map.insert addr updated m, ())
      [] ->
        if length (availableConns nodePool) < maxConnectionsPerNode (poolConfig pool)
          then do
            let updated = nodePool { availableConns = conn : availableConns nodePool }
            return (Map.insert addr updated m, ())
          else do
            -- Shouldn't happen, but close just in case
            close conn `catch` \(_ :: SomeException) -> return ()
            let updated = nodePool { totalConns = totalConns nodePool - 1 }
            return (Map.insert addr updated m, ())

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
    let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
    case waitQueue nodePool of
      (waiter : rest) -> do
        -- Keep slot reserved for the waiter (don't decrement totalConns)
        let updated = nodePool { waitQueue = rest }
        return (Map.insert addr updated m, Just waiter)
      [] -> do
        -- No waiters, just release the slot
        let updated = nodePool { totalConns = totalConns nodePool - 1 }
        return (Map.insert addr updated m, Nothing)
  case maybeWaiter of
    Nothing -> return ()
    Just waiter -> do
      -- Try to create a replacement connection for the waiter
      connResult <- try (connector addr)
      case connResult of
        Right newConn -> putMVar waiter (Right newConn)
        Left (e :: SomeException) -> do
          -- Failed — release the reserved slot and notify waiter of the error
          modifyMVar (poolConnections pool) $ \m -> do
            let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
            return (m', ())
          putMVar waiter (Left e)

-- | Get an existing idle connection or create a new one.
-- Unlike 'withConnection', the returned connection is not exclusively checked out—
-- prefer 'withConnection' for thread-safe usage.
-- Connection creation happens outside the MVar lock to prevent deadlocks.
getOrCreateConnection ::
  (Client client, MonadIO m) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  m (client 'Connected)
getOrCreateConnection pool addr connector = liftIO $ do
  maybeConn <- modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0 []) addr m
    case availableConns nodePool of
      (conn : rest) -> do
        let updated = nodePool { availableConns = rest }
        return (Map.insert addr updated m, Just conn)
      [] -> do
        let updated = nodePool { totalConns = totalConns nodePool + 1 }
        return (Map.insert addr updated m, Nothing)
  case maybeConn of
    Just conn -> return conn
    Nothing -> do
      connResult <- try (connector addr)
      case connResult of
        Right conn -> return conn
        Left (e :: SomeException) -> do
          modifyMVar (poolConnections pool) $ \m -> do
            let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
            return (m', ())
          throwIO e

-- | Close all connections in the pool and wake any blocked waiters.
-- Exceptions during close are caught and ignored.
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool =
  modifyMVar (poolConnections pool) $ \m -> do
    let poolClosed = toException (userError "Connection pool closed")
    forM_ (Map.elems m) $ \nodePool -> do
      forM_ (availableConns nodePool) $ \conn ->
        close conn `catch` \(_ :: SomeException) -> return ()
      -- Wake all blocked waiters with an error
      forM_ (waitQueue nodePool) $ \waiter ->
        putMVar waiter (Left poolClosed)
    return (Map.empty, ())
