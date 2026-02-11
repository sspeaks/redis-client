{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Pool of 'Multiplexer's for cluster-mode usage.
--
-- Manages a single multiplexed connection per node, matching the
-- StackExchange.Redis architecture. Automatically reconnects dead multiplexers.
--
-- @
-- pool <- createMultiplexPool connector
-- resp <- submitToNode pool nodeAddr cmdBytes
-- closeMultiplexPool pool
-- @
module MultiplexPool
  ( MultiplexPool
  , createMultiplexPool
  , submitToNode
  , closeMultiplexPool
  ) where

import Client (Client (..))
import Cluster (NodeAddress (..))
import Connector (Connector)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Control.Exception (SomeException, catch, throwIO)
import Data.IORef (IORef, newIORef, readIORef, atomicWriteIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Multiplexer
  ( Multiplexer
  , SlotPool
  , createSlotPool
  , createMultiplexer
  , destroyMultiplexer
  , isMultiplexerAlive
  , submitCommandPooled
  )
import Resp (RespData)
import qualified Data.ByteString.Builder as Builder

-- | A pool of multiplexers, one per node address.
-- Uses IORef for fast lock-free reads on the hot path,
-- with MVar protecting creation/replacement (exclusive writes).
-- Includes a per-pool SlotPool for ResponseSlot reuse.
data MultiplexPool client = MultiplexPool
  { poolNodesRef   :: !(IORef (Map NodeAddress Multiplexer))  -- fast reads
  , poolNodesLock  :: !(MVar ())                              -- protects writes
  , poolConnector  :: !(Connector client)
  , poolSlotPool   :: !SlotPool                               -- reusable ResponseSlots
  }

-- | Create a new empty multiplexer pool.
-- Multiplexers are created lazily when a node is first accessed.
createMultiplexPool
  :: (Client client)
  => Connector client
  -> IO (MultiplexPool client)
createMultiplexPool connector = do
  nodesRef <- newIORef Map.empty
  nodesLock <- newMVar ()
  slotPool <- createSlotPool 256
  return $ MultiplexPool nodesRef nodesLock connector slotPool

-- | Submit a pre-encoded RESP command (as a Builder) to the multiplexer for a given node.
-- Creates the multiplexer on demand if the node hasn't been seen before.
-- On submission failure (dead multiplexer), replaces it and retries once.
submitToNode
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder
  -> IO RespData
submitToNode pool addr cmdBuilder = do
  mux <- getMultiplexer pool addr
  submitCommandPooled (poolSlotPool pool) mux cmdBuilder
    `catch` \(e :: SomeException) -> do
      -- Multiplexer may be dead; try to replace and retry once
      alive <- isMultiplexerAlive mux
      if alive
        then throwIO e  -- mux is alive, error is something else
        else do
          newMux <- replaceMux pool addr mux
          submitCommandPooled (poolSlotPool pool) newMux cmdBuilder

-- | Get or create the single multiplexer for a node.
-- Uses readIORef for the common path (lock-free, no MVar overhead).
-- Skips isMultiplexerAlive check on the hot path — errors are caught
-- by the caller (submitToNode) which triggers replacement on failure.
getMultiplexer
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO Multiplexer
getMultiplexer pool addr = do
  m <- readIORef (poolNodesRef pool)
  case Map.lookup addr m of
    Just mux -> return mux
    Nothing -> modifyMVar (poolNodesLock pool) $ \() -> do
      -- Double-check after acquiring lock
      m' <- readIORef (poolNodesRef pool)
      case Map.lookup addr m' of
        Just mux -> return ((), mux)
        Nothing -> do
          mux <- createOneMux (poolConnector pool) addr
          atomicWriteIORef (poolNodesRef pool) (Map.insert addr mux m')
          return ((), mux)

-- | Create a single multiplexer for a node address.
createOneMux
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> IO Multiplexer
createOneMux connector addr = do
  conn <- connector addr
  createMultiplexer conn (receive conn)

-- | Replace a dead multiplexer for a node.
replaceMux
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Multiplexer
  -> IO Multiplexer
replaceMux pool addr oldMux = do
  destroyMultiplexer oldMux `catch` \(_ :: SomeException) -> return ()
  modifyMVar (poolNodesLock pool) $ \() -> do
    m <- readIORef (poolNodesRef pool)
    -- Double-check: another thread may have already replaced it
    case Map.lookup addr m of
      Just current -> do
        alive <- isMultiplexerAlive current
        if alive
          then return ((), current)
          else do
            newMux <- createOneMux (poolConnector pool) addr
            atomicWriteIORef (poolNodesRef pool) (Map.insert addr newMux m)
            return ((), newMux)
      Nothing -> do
        newMux <- createOneMux (poolConnector pool) addr
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr newMux m)
        return ((), newMux)

-- | Tear down all multiplexers across all nodes.
closeMultiplexPool
  :: MultiplexPool client
  -> IO ()
closeMultiplexPool pool = do
  modifyMVar (poolNodesLock pool) $ \() -> do
    m <- readIORef (poolNodesRef pool)
    mapM_ (\mux -> destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ())
          (Map.elems m)
    atomicWriteIORef (poolNodesRef pool) Map.empty
    return ((), ())
