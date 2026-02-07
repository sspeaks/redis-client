{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE RankNTypes #-}

-- | Thread-safe connection pool for managing Redis connections.
--
-- Connections are created lazily and managed per-node. Each call to
-- 'withConnection' checks out an exclusive connection for the caller,
-- preventing RESP protocol interleaving between threads. Connections
-- are returned to the pool after use, or discarded if an error occurred.
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
import           Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import           Control.Exception      (SomeException, catch, throwIO, try)
import           Control.Monad          (forM_)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map

-- | Configuration for the connection pool.
data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int  -- ^ Maximum number of connections kept per node. Overflow connections are created but discarded after use.
  , connectionTimeout     :: Int  -- ^ Connection timeout in seconds (reserved for future use).
  , maxRetries            :: Int  -- ^ Maximum retry attempts for cluster operations.
  , useTLS                :: Bool -- ^ Whether to use TLS connections.
  }
  deriving (Show)

-- | Per-node connection state: available connections and total count
data NodePool client = NodePool
  { availableConns :: [client 'Connected]  -- ^ Idle connections ready for checkout
  , totalConns     :: !Int                 -- ^ Total connections created (available + in-use)
  }

-- | Thread-safe connection pool using MVar for atomic access.
-- Each node has a pool of connections; callers check out exclusive
-- connections and return them after use.
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
      -- Discard the connection — it may be in a bad state
      close conn `catch` \(_ :: SomeException) -> return ()
      modifyMVar (poolConnections pool) $ \m -> do
        let m' = Map.adjust (\np -> np { totalConns = totalConns np - 1 }) addr m
        return (m', ())
      throwIO e

-- | Check out a connection from the pool. Creates a new one if none available
-- and the max hasn't been reached.
checkoutConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  IO (client 'Connected)
checkoutConnection pool addr connector = do
  maybeConn <- modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0) addr m
    case availableConns nodePool of
      (conn : rest) -> do
        let updated = nodePool { availableConns = rest }
        return (Map.insert addr updated m, Just conn)
      [] -> do
        if totalConns nodePool < maxConnectionsPerNode (poolConfig pool)
          then do
            let updated = nodePool { totalConns = totalConns nodePool + 1 }
            return (Map.insert addr updated m, Nothing)
          else
            -- At max — allow a temporary overflow connection
            return (m, Nothing)
  case maybeConn of
    Just conn -> return conn
    Nothing   -> connector addr

-- | Return a connection to the pool for reuse.
returnConnection ::
  (Client client) =>
  ConnectionPool client ->
  NodeAddress ->
  client 'Connected ->
  IO ()
returnConnection pool addr conn =
  modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0) addr m
    if length (availableConns nodePool) < maxConnectionsPerNode (poolConfig pool)
      then do
        let updated = nodePool { availableConns = conn : availableConns nodePool }
        return (Map.insert addr updated m, ())
      else do
        -- Pool is full, discard overflow connection
        close conn `catch` \(_ :: SomeException) -> return ()
        return (m, ())

-- | Get an existing idle connection or create a new one.
-- Unlike 'withConnection', the returned connection is not exclusively checked out—
-- prefer 'withConnection' for thread-safe usage.
getOrCreateConnection ::
  (Client client, MonadIO m) =>
  ConnectionPool client ->
  NodeAddress ->
  Connector client ->
  m (client 'Connected)
getOrCreateConnection pool addr connector = liftIO $
  modifyMVar (poolConnections pool) $ \m -> do
    let nodePool = Map.findWithDefault (NodePool [] 0) addr m
    case availableConns nodePool of
      (conn : rest) -> do
        let updated = nodePool { availableConns = rest }
        return (Map.insert addr updated m, conn)
      [] -> do
        conn <- connector addr
        let updated = nodePool { totalConns = totalConns nodePool + 1 }
        return (Map.insert addr updated m, conn)

-- | Close all connections in the pool.
-- Exceptions during close are caught and ignored.
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool =
  modifyMVar (poolConnections pool) $ \m -> do
    forM_ (Map.elems m) $ \nodePool ->
      forM_ (availableConns nodePool) $ \conn ->
        close conn `catch` \(_ :: SomeException) -> return ()
    return (Map.empty, ())
