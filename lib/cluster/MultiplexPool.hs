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
  , submitToNodeAsync
  , waitSlotResult
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
  , ResponseSlot
  , createSlotPool
  , createMultiplexer
  , destroyMultiplexer
  , isMultiplexerAlive
  , submitCommandPooled
  , submitCommandAsync
  , waitSlot
  )
import Resp (RespData)
import qualified Data.ByteString.Builder as Builder

-- | Per-node multiplexer group with its own round-robin counter.
-- Keeping the counter per-node eliminates cross-node CAS contention
-- on the shared counter that existed before.
data NodeMuxes = NodeMuxes
  { nmMuxes   :: !(Vector Multiplexer)
  , nmCounter :: !(IORef Int)
  }

-- | A pool of multiplexers, N per node address (round-robin selected).
-- Uses IORef for fast lock-free reads on the hot path,
-- with MVar protecting creation/replacement (exclusive writes).
-- Includes a per-pool SlotPool for ResponseSlot reuse.
data MultiplexPool client = MultiplexPool
  { poolNodesRef   :: !(IORef (Map NodeAddress NodeMuxes))    -- fast reads
  , poolNodesLock  :: !(MVar ())                              -- protects writes
  , poolConnector  :: !(Connector client)
  , poolSlotPool   :: !SlotPool                               -- reusable ResponseSlots
  , poolMuxCount   :: !Int                                    -- multiplexers per node
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
  return $ MultiplexPool nodesRef nodesLock connector slotPool (max 1 muxCnt)

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
{-# INLINE submitToNode #-}

-- | Async version of submitToNode: enqueue the command and return a ResponseSlot.
-- Caller must later call 'waitSlotResult' to get the response.
submitToNodeAsync
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder
  -> IO ResponseSlot
submitToNodeAsync pool addr cmdBuilder = do
  mux <- getMultiplexer pool addr
  submitCommandAsync (poolSlotPool pool) mux cmdBuilder
{-# INLINE submitToNodeAsync #-}

-- | Wait for an async submission's result and release the slot.
waitSlotResult :: MultiplexPool client -> ResponseSlot -> IO RespData
waitSlotResult pool slot = waitSlot (poolSlotPool pool) slot
{-# INLINE waitSlotResult #-}

-- | Get or create a multiplexer for a node, round-robin among N muxes.
-- Uses readIORef for the common path (lock-free, no MVar overhead).
-- Per-node counter eliminates cross-node CAS contention.
-- When only 1 mux per node, skips the counter entirely.
getMultiplexer
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO Multiplexer
getMultiplexer pool addr = do
  m <- readIORef (poolNodesRef pool)
  case Map.lookup addr m of
    Just nm -> pickMux nm
    Nothing -> modifyMVar (poolNodesLock pool) $ \() -> do
      -- Double-check after acquiring lock
      m' <- readIORef (poolNodesRef pool)
      case Map.lookup addr m' of
        Just nm -> do
          mux <- pickMux nm
          return ((), mux)
        Nothing -> do
          nm <- createNodeMuxes (poolConnector pool) addr (poolMuxCount pool)
          atomicWriteIORef (poolNodesRef pool) (Map.insert addr nm m')
          return ((), V.head (nmMuxes nm))
{-# INLINE getMultiplexer #-}

-- | Pick a multiplexer from a NodeMuxes using round-robin.
-- Fast path: single mux skips atomic counter entirely.
pickMux :: NodeMuxes -> IO Multiplexer
pickMux nm
  | V.length (nmMuxes nm) == 1 = return $! V.unsafeHead (nmMuxes nm)
  | otherwise = do
      idx <- atomicModifyIORef' (nmCounter nm) (\n -> (n + 1, n))
      return $! nmMuxes nm `V.unsafeIndex` (idx `mod` V.length (nmMuxes nm))
{-# INLINE pickMux #-}

-- | Create N multiplexers for a node address, bundled with a per-node counter.
createNodeMuxes
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> Int
  -> IO NodeMuxes
createNodeMuxes connector addr count = do
  muxes <- V.generateM count $ \_ -> do
    conn <- connector addr
    createMultiplexer conn (receive conn)
  counter <- newIORef 0
  return $ NodeMuxes muxes counter

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
      Just nm -> do
        -- Find and replace the dead mux in the vector
        newMuxes <- V.mapM (\mux -> do
          alive <- isMultiplexerAlive mux
          if alive
            then return mux
            else do
              conn <- (poolConnector pool) addr
              createMultiplexer conn (receive conn)
          ) (nmMuxes nm)
        let nm' = nm { nmMuxes = newMuxes }
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr nm' m)
        -- Return the first alive one
        mux <- pickMux nm'
        return ((), mux)
      Nothing -> do
        nm <- createNodeMuxes (poolConnector pool) addr (poolMuxCount pool)
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr nm m)
        return ((), V.head (nmMuxes nm))

-- | Tear down all multiplexers across all nodes.
closeMultiplexPool
  :: MultiplexPool client
  -> IO ()
closeMultiplexPool pool = do
  modifyMVar (poolNodesLock pool) $ \() -> do
    m <- readIORef (poolNodesRef pool)
    mapM_ (\nm -> V.mapM_ (\mux -> destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ()) (nmMuxes nm))
          (Map.elems m)
    atomicWriteIORef (poolNodesRef pool) Map.empty
    return ((), ())
