{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

-- | Pool of 'Multiplexer's for cluster-mode usage.
--
-- Manages one or more multiplexed connections per node, matching the
-- StackExchange.Redis architecture. Automatically reconnects dead multiplexers
-- until the pool is closed.
--
-- @
-- pool <- createMultiplexPool connector 1
-- resp <- submitToNode pool nodeAddr cmdBytes
-- closeMultiplexPool pool
-- @
--
-- @since 0.1.0.0
module Database.Redis.Internal.MultiplexPool
  ( MultiplexPool
  , MultiplexPoolException (..)
  , createMultiplexPool
  , submitToNode
  , submitToNodeWithAsking
  , submitToNodeAsync
  , waitSlotResult
  , closeMultiplexPool
  ) where

import           Control.Concurrent.MVar             (MVar, modifyMVar, newMVar)
import           Control.Exception                   (Exception, SomeException,
                                                      catch, mask, throwIO, try)
import qualified Data.ByteString.Builder             as Builder
import           Data.IORef                          (IORef, atomicModifyIORef',
                                                      atomicWriteIORef,
                                                      newIORef, readIORef)
import           Data.Map.Strict                     (Map)
import qualified Data.Map.Strict                     as Map
import           Data.Typeable                       (Typeable)
import           Data.Vector                         (Vector)
import qualified Data.Vector                         as V
import           Database.Redis.Client               (Client (..))
import           Database.Redis.Cluster              (NodeAddress (..))
import           Database.Redis.Connector            (Connector)
import           Database.Redis.Internal.Multiplexer (Multiplexer, ResponseSlot,
                                                      SlotPool,
                                                      createMultiplexer,
                                                      createSlotPool,
                                                      destroyMultiplexer,
                                                      isMultiplexerAlive,
                                                      submitCommandAsync,
                                                      submitCommandPairPooled,
                                                      submitCommandPooled,
                                                      waitSlot)
import           Database.Redis.Resp                 (RespData)

-- | Exception thrown when a terminally closed multiplexer pool is used.
data MultiplexPoolException = MultiplexPoolClosed
  deriving (Eq, Show, Typeable)

instance Exception MultiplexPoolException

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
  { poolNodesRef  :: !(IORef (Map NodeAddress NodeMuxes))    -- fast reads
  , poolNodesLock :: !(MVar ())                              -- protects writes
  , poolClosed    :: !(IORef Bool)                           -- terminal state
  , poolConnector :: !(Connector client)
  , poolSlotPool  :: !SlotPool                               -- reusable ResponseSlots
  , poolMuxCount  :: !Int                                    -- multiplexers per node
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
  closed <- newIORef False
  slotPool <- createSlotPool 256
  return $ MultiplexPool nodesRef nodesLock closed connector slotPool (max 1 muxCnt)

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

-- | Submit an ASKING command followed by a real command atomically to a node.
-- Both commands are enqueued in a single atomic operation so no other command
-- can be interleaved between them on the same connection. The ASKING response
-- is discarded; only the real command's response is returned.
submitToNodeWithAsking
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder  -- ^ ASKING command builder
  -> Builder.Builder  -- ^ The actual command builder
  -> IO RespData
submitToNodeWithAsking pool addr askingBuilder cmdBuilder = do
  mux <- getMultiplexer pool addr
  submitCommandPairPooled (poolSlotPool pool) mux askingBuilder cmdBuilder
    `catch` \(e :: SomeException) -> do
      alive <- isMultiplexerAlive mux
      if alive
        then throwIO e
        else do
          newMux <- replaceMux pool addr mux
          submitCommandPairPooled (poolSlotPool pool) newMux askingBuilder cmdBuilder
{-# INLINE submitToNodeWithAsking #-}

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
  ensurePoolOpen pool
  m <- readIORef (poolNodesRef pool)
  case Map.lookup addr m of
    Just nm -> pickMux nm
    Nothing -> modifyMVar (poolNodesLock pool) $ \() -> do
      ensurePoolOpen pool
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
  muxes <- mask $ \restore -> createAll restore [] count
  counter <- newIORef 1 `catch` \(e :: SomeException) -> do
    destroyMuxes muxes
    throwIO e
  return $ NodeMuxes (V.fromList $ reverse muxes) counter
  where
    createAll _ acc 0 = return acc
    createAll restore acc remaining = do
      result <- try $ restore $ do
        conn <- connector addr
        createMultiplexer conn (receive conn)
      case result of
        Right mux -> createAll restore (mux : acc) (remaining - 1)
        Left (e :: SomeException) -> do
          destroyMuxes acc
          throwIO e

-- | Replace a dead multiplexer for a node.
replaceMux
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Multiplexer
  -> IO Multiplexer
replaceMux pool addr _oldMux = do
  modifyMVar (poolNodesLock pool) $ \() -> do
    ensurePoolOpen pool
    m <- readIORef (poolNodesRef pool)
    case Map.lookup addr m of
      Just nm -> do
        newMuxes <- replaceDeadMuxes pool addr (V.toList $ nmMuxes nm)
        let nm' = nm { nmMuxes = V.fromList newMuxes }
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr nm' m)
        -- Return the first alive one
        mux <- pickMux nm'
        return ((), mux)
      Nothing -> do
        nm <- createNodeMuxes (poolConnector pool) addr (poolMuxCount pool)
        atomicWriteIORef (poolNodesRef pool) (Map.insert addr nm m)
        return ((), V.head (nmMuxes nm))

-- | Tear down all multiplexers and their owned transports across all nodes.
-- Closure is terminal and idempotent; later submissions throw
-- 'MultiplexPoolClosed' rather than reconnecting.
closeMultiplexPool
  :: MultiplexPool client
  -> IO ()
closeMultiplexPool pool = do
  muxes <- modifyMVar (poolNodesLock pool) $ \() -> do
    alreadyClosed <- readIORef (poolClosed pool)
    m <- readIORef (poolNodesRef pool)
    if alreadyClosed
      then return ((), [])
      else do
        atomicWriteIORef (poolClosed pool) True
        atomicWriteIORef (poolNodesRef pool) Map.empty
        return ((), concatMap (V.toList . nmMuxes) $ Map.elems m)
  destroyMuxes muxes

ensurePoolOpen :: MultiplexPool client -> IO ()
ensurePoolOpen pool = do
  closed <- readIORef (poolClosed pool)
  if closed then throwIO MultiplexPoolClosed else return ()

destroyMuxes :: [Multiplexer] -> IO ()
destroyMuxes =
  mapM_ (\mux -> destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ())

replaceDeadMuxes
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> [Multiplexer]
  -> IO [Multiplexer]
replaceDeadMuxes pool addr muxes =
  mask $ \restore -> go restore [] [] muxes
  where
    go _ kept _ [] = return $ reverse kept
    go restore kept created (mux:rest) = do
      alive <- isMultiplexerAlive mux
      if alive
        then go restore (mux : kept) created rest
        else do
          destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ()
          result <- try $ restore $ do
            conn <- poolConnector pool addr
            createMultiplexer conn (receive conn)
          case result of
            Right newMux -> go restore (newMux : kept) (newMux : created) rest
            Left (e :: SomeException) -> do
              destroyMuxes created
              throwIO e
