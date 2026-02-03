{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module ConnectionPool
  ( ConnectionPool (..),
    PoolConfig (..),
    createPool,
    getOrCreateConnection,
    closePool,
  )
where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (NotConnectedTLSClient))
import Cluster (NodeAddress (..))
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (bracket, catch, SomeException)
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

-- | Configuration for the connection pool
data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int, -- Default: 1 (can scale up)
    connectionTimeout :: Int,
    maxRetries :: Int,
    useTLS :: Bool
  }
  deriving (Show)

-- | Connection pool that manages connections to multiple nodes
-- Uses TVar for thread-safe access
data ConnectionPool client = ConnectionPool
  { poolConnections :: TVar (Map NodeAddress (client 'Connected)),
    poolConfig :: PoolConfig
  }

-- | Create a new empty connection pool
createPool :: PoolConfig -> IO (ConnectionPool client)
createPool config = do
  connections <- newTVarIO Map.empty
  return $ ConnectionPool connections config

-- | Get an existing connection or create a new one for PlainText
-- This is lazy - connections are only created when first needed
getOrCreateConnection ::
  (Client client, MonadIO m) =>
  ConnectionPool client ->
  NodeAddress ->
  (NodeAddress -> IO (client 'Connected)) ->
  m (client 'Connected)
getOrCreateConnection pool addr connector = liftIO $ do
  connMap <- atomically $ readTVar (poolConnections pool)
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
closePool :: (Client client) => ConnectionPool client -> IO ()
closePool pool = do
  connMap <- atomically $ readTVar (poolConnections pool)
  forM_ (Map.elems connMap) $ \conn -> do
    close conn `catch` \(_ :: SomeException) -> return ()
  atomically $ writeTVar (poolConnections pool) Map.empty
