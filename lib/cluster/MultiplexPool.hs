{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Pool of 'Multiplexer's for cluster-mode usage.
--
-- Manages one or more multiplexed connections per node, matching the
-- StackExchange.Redis architecture. Automatically reconnects dead multiplexers.
--
-- @
-- pool <- createMultiplexPool connector 1
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
import Data.IORef (IORef, newIORef, readIORef, atomicWriteIORef, atomicModifyIORef')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Vector (Vector)
import qualified Data.Vector as V
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

-- | A pool of multiplexers, N per node address (round-robin selected).
-- Uses IORef for fast lock-free reads on the hot path,
-- with MVar protecting creation/replacement (exclusive writes).
-- Includes a per-pool SlotPool for ResponseSlot reuse.
data MultiplexPool client = MultiplexPool
  { poolNodesRef   :: !(IORef (Map NodeAddress (Vector Multiplexer)))  -- fast reads
  , poolNodesLock  :: !(MVar ())                              -- protects writes
  , poolConnector  :: !(Connector client)
  , poolSlotPool   :: !SlotPool                               -- reusable ResponseSlots
  , poolMuxCount   :: !Int                                    -- multiplexers per node
  , poolCounter    :: !(IORef Int)                             -- round-robin counter
  }

-- | Create a new empty multiplexer pool.
-- Multiplexers are created lazily when a node is first accessed.
-- @muxCount@ controls how many multiplexers are created per node.
createMultiplexPool
  :: (Client client)
  => Connector client
  -> Int
  -> IO (MultiplexPool client)
createMultiplexPool connector muxCnt = do
  nodesRef <- newIORef Map.empty
  nodesLock <- newMVar ()
  slotPool <- createSlotPool 256
  counter <- newIORef 0
  return $ MultiplexPool nodesRef nodesLock connector slotPool (max 1 muxCnt) counter

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

-- | Get or create a multiplexer for a node, round-robin among N muxes.
-- Uses readIORef for the common path (lock-free, no MVar overhead).
getMultiplexer
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO Multiplexer
getMultiplexer pool addr = do
  m <- readIORef (poolNodesRef pool)
  case Map.lookup addr m of
    Just muxes -> do
      idx <- atomicModifyIORef' (poolCounter pool) (\n -> (n + 1, n))
      return $! muxes V.! (idx `mod` V.length muxes)
    Nothing -> modifyMVar (poolNodesLock pool) $ \() -> do
      -- Double-check after acquiring lock
      m' <- readIORef (poolNodesRef pool)
      case Map.lookup addr m' of
        Just muxes -> do
          idx <- atomicModifyIORef' (poolCounter pool) (\n -> (n + 1, n))
          return ((), muxes V.! (idx `mod` V.length muxes))
        Nothing -> do
          muxes <- createMuxes (poolConnector pool) addr (poolMuxCount pool)
          atomicWriteIORef (poolNodesRef pool) (Map.insert addr muxes m')
          return ((), V.head muxes)

-- | Create N multiplexers for a node address.
createMuxes
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> Int
  -> IO (Vector Multiplexer)
createMuxes connector addr count =
  V.generateM count $ \_ -> do
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
    case Map.lookup addr m of
      Just muxes -> do
        -- Find and replace the dead mux in the vector
        newMuxes <- V.mapM (\mux -> do
          alive <- isMultiplexerAlive mux
          if alive
            then return mux
            else do
              conn <- (poolConnector pool) addr
              createMultiplexer conn (receive conn)
          ) muxes
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr newMuxes m)
        -- Return the first alive one
        idx <- atomicModifyIORef' (poolCounter pool) (\n -> (n + 1, n))
        return ((), newMuxes V.! (idx `mod` V.length newMuxes))
      Nothing -> do
        muxes <- createMuxes (poolConnector pool) addr (poolMuxCount pool)
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr muxes m)
        return ((), V.head muxes)

-- | Tear down all multiplexers across all nodes.
closeMultiplexPool
  :: MultiplexPool client
  -> IO ()
closeMultiplexPool pool = do
  modifyMVar (poolNodesLock pool) $ \() -> do
    m <- readIORef (poolNodesRef pool)
    mapM_ (\muxes -> V.mapM_ (\mux -> destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ()) muxes)
          (Map.elems m)
    atomicWriteIORef (poolNodesRef pool) Map.empty
    return ((), ())
