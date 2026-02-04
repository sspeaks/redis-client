{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE RankNTypes #-}

module ConnectionPool
  ( ConnectionPool (..),
    PoolConfig (..),
    createPool,
    getOrCreateConnection,
    closePool,
  )
where

import           Client                 (Client (..), ConnectionStatus (..),
                                         PlainTextClient (NotConnectedPlainTextClient),
                                         TLSClient (NotConnectedTLSClient))
import           Cluster                (NodeAddress (..))
import           Control.Concurrent.STM (STM, TVar, atomically, newTVarIO,
                                         readTVar, readTVarIO, writeTVar)
import           Control.Exception      (SomeException, bracket, catch)
import           Control.Monad          (forM_)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map

-- | Configuration for the connection pool
data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int, -- ^ Default: 1 (can scale up)
    connectionTimeout     :: Int, -- ^ Connection timeout in microseconds
    maxRetries            :: Int, -- ^ Maximum retry attempts
    useTLS                :: Bool -- ^ Whether to use TLS connections
  }
  deriving (Show)

-- | Connection pool that manages connections to multiple nodes
-- Uses TVar for thread-safe access
data ConnectionPool client = ConnectionPool
  { poolConnections :: TVar (Map NodeAddress (client 'Connected)), -- ^ Active connections
    poolConfig      :: PoolConfig                                  -- ^ Pool configuration
  }

-- | Create a new empty connection pool
-- Connections are created lazily when first requested
createPool :: PoolConfig -> IO (ConnectionPool client)
createPool config = do
  connections <- newTVarIO Map.empty
  return $ ConnectionPool connections config

-- | Get an existing connection or create a new one for a specific node address
-- This is lazy - connections are only created when first needed
-- Thread-safe: Multiple threads can safely request connections
-- 
-- The connector function is called only if a connection doesn't exist
getOrCreateConnection ::
  (Client client, MonadIO m) =>
  ConnectionPool client ->
  NodeAddress ->
  (NodeAddress -> IO (client 'Connected)) -> -- ^ Function to create new connections
  m (client 'Connected)
getOrCreateConnection pool addr connector = liftIO $ do
  connMap <- readTVarIO (poolConnections pool)
  case Map.lookup addr connMap of
    Just conn -> return conn
    Nothing -> do
      -- Create new connection using the provided connector
      conn <- connector addr
      -- Store in pool
      atomically $ do
        currentMap <- readTVar (poolConnections pool)
        writeTVar (poolConnections pool) (Map.insert addr conn currentMap)
      return conn

-- | Close all connections in the pool
-- Exceptions during close are caught and ignored
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool = do
  connMap <- readTVarIO (poolConnections pool)
  forM_ (Map.elems connMap) $ \conn -> do
    close conn `catch` \(_ :: SomeException) -> return ()
  atomically $ writeTVar (poolConnections pool) Map.empty
