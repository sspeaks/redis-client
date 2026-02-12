{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

-- | Multiplexed command pipelining over a single Redis connection.
--
-- A 'Multiplexer' wraps a connected client with a writer thread (batches and
-- sends commands) and a reader thread (parses responses and dispatches them
-- to callers). Multiple threads submit commands concurrently via
-- 'submitCommand'; the FIFO ordering guarantee of Redis pipelining ensures
-- correct response demultiplexing without message IDs.
--
-- @
-- mux <- createMultiplexer conn recv
-- resp <- submitCommand mux (encode [\"GET\", \"key\"])
-- destroyMultiplexer mux
-- @
module Multiplexer
  ( Multiplexer
  , MultiplexerException (..)
  , SlotPool
  , ResponseSlot
  , createSlotPool
  , createMultiplexer
  , submitCommand
  , submitCommandPooled
  , submitCommandAsync
  , waitSlot
  , acquireSlot
  , releaseSlot
  , destroyMultiplexer
  , isMultiplexerAlive
  ) where

import Client (Client (..), ConnectionStatus (..))
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import qualified GHC.Conc as GHC (threadCapability)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception
  ( Exception
  , SomeException
  , mask_
  , throwIO
  , toException
  , try
  )
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Builder.Extra as Builder (toLazyByteStringWith, untrimmedStrategy)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicWriteIORef, atomicModifyIORef')
import Data.List (foldl')
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
import qualified Data.Vector as V
import Resp (RespData, parseRespData)

-- | Exception thrown when submitting to a dead multiplexer.
data MultiplexerException
  = MultiplexerDead String
  | MultiplexerParseError String
  | MultiplexerConnectionClosed
  deriving (Show, Typeable)

instance Exception MultiplexerException

-- | Response slot: an IORef for the result and an MVar for signaling.
-- The reader writes the result to the IORef, then signals the MVar.
-- The caller waits on the MVar, then reads the IORef.
-- This avoids the heavier MVar write+wakeup pattern for the result itself.
data ResponseSlot = ResponseSlot
  { slotResult :: !(IORef (Maybe (Either SomeException RespData)))
  , slotSignal :: !(MVar ())
  }

-- | Striped pool of pre-allocated ResponseSlots.
-- Uses multiple IORef-based stacks indexed by capability (core) to reduce
-- CAS contention between threads on different cores.
data SlotPool = SlotPool
  { spStripes :: !(V.Vector (IORef [ResponseSlot]))
  , spNumStripes :: !Int
  }

-- | Create a striped pool. Each stripe gets @n `div` numStripes@ pre-allocated slots.
createSlotPool :: Int -> IO SlotPool
createSlotPool n = do
  let numStripes = 16
      perStripe = max 4 (n `div` numStripes)
  stripes <- V.replicateM numStripes $ do
    slots <- mapM (\_ -> do
      r <- newIORef Nothing
      s <- newEmptyMVar
      return $ ResponseSlot r s
      ) [1..perStripe]
    newIORef slots
  return $ SlotPool stripes numStripes

-- | Pick a stripe based on the current thread's capability.
getStripe :: SlotPool -> IO (IORef [ResponseSlot])
getStripe sp = do
  tid <- myThreadId
  (cap, _) <- GHC.threadCapability tid
  let !idx = cap `mod` spNumStripes sp
  return $! spStripes sp V.! idx
{-# INLINE getStripe #-}

-- | Acquire a ResponseSlot from the pool, or allocate a fresh one if empty.
-- Resets the slot's IORef to Nothing before returning.
acquireSlot :: SlotPool -> IO ResponseSlot
acquireSlot sp = do
  ref <- getStripe sp
  mSlot <- atomicModifyIORef' ref $ \case
    []     -> ([], Nothing)
    (x:xs) -> (xs, Just x)
  case mSlot of
    Just slot -> do
      writeIORef (slotResult slot) Nothing
      return slot
    Nothing -> do
      r <- newIORef Nothing
      s <- newEmptyMVar
      return $ ResponseSlot r s
{-# INLINE acquireSlot #-}

-- | Return a ResponseSlot to the pool for reuse.
releaseSlot :: SlotPool -> ResponseSlot -> IO ()
releaseSlot sp slot = do
  ref <- getStripe sp
  atomicModifyIORef' ref $ \xs -> (slot : xs, ())
{-# INLINE releaseSlot #-}

-- | A command waiting to be sent, paired with a response slot.
data PendingCommand = PendingCommand
  { pcBuilder  :: !Builder.Builder
  , pcSlot     :: !ResponseSlot
  }

-- | SPSC queue for pending response slots.
-- Writer is sole producer, reader is sole consumer.
-- Uses IORef + MVar signaling instead of STM TQueue.
data PendingQueue = PendingQueue
  { pqSlots  :: !(IORef (Seq ResponseSlot))
  , pqSignal :: !(MVar ())  -- signaled when new items are available
  }

newPendingQueue :: IO PendingQueue
newPendingQueue = do
  slots <- newIORef Seq.empty
  signal <- newEmptyMVar
  return $ PendingQueue slots signal

-- | Enqueue a Seq of response slots directly (avoids Seq.fromList conversion).
pendingEnqueueSeq :: PendingQueue -> Seq ResponseSlot -> IO ()
pendingEnqueueSeq pq newSlots = do
  atomicModifyIORef' (pqSlots pq) $ \s ->
    (s <> newSlots, ())
  void $ tryPutMVar (pqSignal pq) ()
{-# INLINE pendingEnqueueSeq #-}

-- | Dequeue one response slot (reader thread only — single consumer).
-- Blocks if empty.
pendingDequeue :: PendingQueue -> IO ResponseSlot
pendingDequeue pq = do
  mSlot <- atomicModifyIORef' (pqSlots pq) $ \s ->
    case Seq.viewl s of
      Seq.EmptyL  -> (s, Nothing)
      x Seq.:< xs -> (xs, Just x)
  case mSlot of
    Just slot -> return slot
    Nothing -> do
      takeMVar (pqSignal pq)
      pendingDequeue pq
{-# INLINE pendingDequeue #-}

-- | Non-blocking dequeue of up to N response slots.
-- Returns empty Seq if none available.
pendingDequeueUpTo :: PendingQueue -> Int -> IO (Seq ResponseSlot)
pendingDequeueUpTo pq n = do
  atomicModifyIORef' (pqSlots pq) $ \s ->
    let (taken, rest) = Seq.splitAt n s
    in (rest, taken)
{-# INLINE pendingDequeueUpTo #-}

-- | Drain all pending slots (for error propagation).
pendingDrainAll :: PendingQueue -> IO [ResponseSlot]
pendingDrainAll pq = do
  slots <- atomicModifyIORef' (pqSlots pq) $ \s -> (Seq.empty, s)
  return $ foldr (:) [] slots

-- | Lock-free MPSC (multi-producer, single-consumer) command queue.
-- Producers use atomicModifyIORef' to cons onto the list (single CAS).
-- The consumer reverses once per drain. MVar signals new item availability.
data CommandQueue = CommandQueue
  { cqItems    :: !(IORef [PendingCommand])  -- reverse order (newest first)
  , cqSignal   :: !(MVar ())                 -- wake writer when items available
  }

newCommandQueue :: IO CommandQueue
newCommandQueue = do
  items  <- newIORef []
  signal <- newEmptyMVar
  return $ CommandQueue items signal

-- | Enqueue a command (caller thread — multi-producer safe).
commandEnqueue :: CommandQueue -> PendingCommand -> IO ()
commandEnqueue cq pc = do
  atomicModifyIORef' (cqItems cq) $ \xs -> (pc : xs, ())
  void $ tryPutMVar (cqSignal cq) ()
{-# INLINE commandEnqueue #-}

-- | Drain all commands (writer thread only — single consumer).
-- Blocks if empty. Returns commands in submission order.
commandDrain :: CommandQueue -> IO [PendingCommand]
commandDrain cq = do
  takeMVar (cqSignal cq)
  batch <- atomicModifyIORef' (cqItems cq) $ \xs -> ([], xs)
  return (reverse batch)

-- | Non-blocking drain of any additional commands that have arrived.
-- Returns commands in submission order. Returns [] if none available.
commandTryDrain :: CommandQueue -> IO [PendingCommand]
commandTryDrain cq = do
  batch <- atomicModifyIORef' (cqItems cq) $ \xs -> ([], xs)
  case batch of
    [] -> return []
    _  -> return (reverse batch)

-- | Drain remaining commands without blocking (for cleanup).
commandFlush :: CommandQueue -> IO [PendingCommand]
commandFlush cq = do
  batch <- atomicModifyIORef' (cqItems cq) $ \xs -> ([], xs)
  return (reverse batch)

-- | A multiplexer wrapping a single Redis connection.
data Multiplexer = Multiplexer
  { muxCommandQueue :: !CommandQueue
  , muxWriterThread :: !ThreadId
  , muxReaderThread :: !ThreadId
  , muxAlive        :: !(IORef Bool)
  }

-- | Create a multiplexer over an already-connected client.
--
-- Spawns a writer and reader green thread. The caller must eventually call
-- 'destroyMultiplexer' to clean up.
createMultiplexer
  :: (Client client)
  => client 'Connected
  -> IO ByteString       -- ^ Action to receive bytes from the connection
  -> IO Multiplexer
createMultiplexer conn recv = do
  cmdQueue     <- newCommandQueue
  pendingQueue <- newPendingQueue
  alive        <- newIORef True

  readerId <- forkIO $ readerLoop pendingQueue recv alive
  writerId <- forkIO $ writerLoop cmdQueue pendingQueue conn alive

  return $ Multiplexer cmdQueue writerId readerId alive

-- | Submit a pre-encoded RESP command as a Builder and block until the response arrives.
submitCommand :: Multiplexer -> Builder.Builder -> IO RespData
submitCommand mux cmdBuilder = do
  isAlive <- readIORef (muxAlive mux)
  if not isAlive
    then throwIO $ MultiplexerDead "Multiplexer is not alive"
    else do
      resultRef <- newIORef Nothing
      signal <- newEmptyMVar
      let slot = ResponseSlot resultRef signal
          pending = PendingCommand cmdBuilder slot
      commandEnqueue (muxCommandQueue mux) pending
      takeMVar signal
      mResult <- readIORef resultRef
      case mResult of
        Just (Right resp) -> return resp
        Just (Left e)     -> throwIO e
        Nothing           -> throwIO $ MultiplexerDead "Response slot empty after signal"

-- | Like 'submitCommand', but acquires a 'ResponseSlot' from the pool
-- instead of allocating a fresh IORef+MVar per call.
submitCommandPooled :: SlotPool -> Multiplexer -> Builder.Builder -> IO RespData
submitCommandPooled pool mux cmdBuilder = do
  isAlive <- readIORef (muxAlive mux)
  if not isAlive
    then throwIO $ MultiplexerDead "Multiplexer is not alive"
    else do
      slot <- acquireSlot pool
      let pending = PendingCommand cmdBuilder slot
      commandEnqueue (muxCommandQueue mux) pending
      takeMVar (slotSignal slot)
      mResult <- readIORef (slotResult slot)
      releaseSlot pool slot
      case mResult of
        Just (Right resp) -> return resp
        Just (Left e)     -> throwIO e
        Nothing           -> throwIO $ MultiplexerDead "Response slot empty after signal"
{-# INLINE submitCommandPooled #-}

-- | Submit a command asynchronously: enqueue it and return the ResponseSlot.
-- The caller must later call 'waitSlot' to get the result, then 'releaseSlot'.
submitCommandAsync :: SlotPool -> Multiplexer -> Builder.Builder -> IO ResponseSlot
submitCommandAsync pool mux cmdBuilder = do
  isAlive <- readIORef (muxAlive mux)
  if not isAlive
    then throwIO $ MultiplexerDead "Multiplexer is not alive"
    else do
      slot <- acquireSlot pool
      let pending = PendingCommand cmdBuilder slot
      commandEnqueue (muxCommandQueue mux) pending
      return slot
{-# INLINE submitCommandAsync #-}

-- | Wait for an async submission's result and release the slot back to the pool.
waitSlot :: SlotPool -> ResponseSlot -> IO RespData
waitSlot pool slot = do
  takeMVar (slotSignal slot)
  mResult <- readIORef (slotResult slot)
  releaseSlot pool slot
  case mResult of
    Just (Right resp) -> return resp
    Just (Left e)     -> throwIO e
    Nothing           -> throwIO $ MultiplexerDead "Response slot empty after signal"
{-# INLINE waitSlot #-}

-- | Tear down the multiplexer: kill both threads and fail all pending commands.
destroyMultiplexer :: Multiplexer -> IO ()
destroyMultiplexer mux = mask_ $ do
  atomicWriteIORef (muxAlive mux) False
  killThread (muxWriterThread mux)
  killThread (muxReaderThread mux)
  remaining <- commandFlush (muxCommandQueue mux)
  let err = MultiplexerDead "Multiplexer destroyed"
  forM_ remaining $ \pc ->
    failSlot (pcSlot pc) (toException err)

-- | Check if the multiplexer's threads are still running.
isMultiplexerAlive :: Multiplexer -> IO Bool
isMultiplexerAlive = readIORef . muxAlive

-- Writer thread: drains command queue, pushes response slots onto pending
-- queue (in IO, not STM), and sends batched bytes over the wire.
writerLoop
  :: (Client client)
  => CommandQueue
  -> PendingQueue
  -> client 'Connected
  -> IORef Bool
  -> IO ()
writerLoop cmdQueue pendingQueue conn alive = go
  where
    go = do
      isAlive <- readIORef alive
      if not isAlive
        then return ()
        else do
          -- Drain command queue (lock-free MPSC, blocks if empty)
          batch <- commandDrain cmdQueue
          -- Non-blocking double-drain: pick up extra commands that arrived
          extra <- commandTryDrain cmdQueue
          let allCmds = batch ++ extra

          -- Single-pass: extract slots (as Seq) and build the combined Builder
          let (!slots, !builder) = foldl'
                (\(!sAcc, !bAcc) pc -> (sAcc Seq.|> pcSlot pc, bAcc <> pcBuilder pc))
                (Seq.empty, mempty)
                allCmds

          -- Push response slots to pending queue (Seq avoids fromList conversion)
          pendingEnqueueSeq pendingQueue slots

          -- Materialize with large buffer strategy and send via vectored I/O.
          -- untrimmedStrategy avoids trimming/copying the final chunk.
          -- 32KB initial / 64KB growth reduces chunk count vs default 4KB.
          -- sendChunks uses writev(2) for zero-copy vectored I/O on plain sockets.
          let !lbs = Builder.toLazyByteStringWith
                       (Builder.untrimmedStrategy 32768 65536) LBS.empty builder
              !chunks = LBS.toChunks lbs
          result <- try $ sendChunks conn chunks
          case result of
            Right () -> go
            Left (e :: SomeException) -> do
              atomicWriteIORef alive False
              remaining <- pendingDrainAll pendingQueue
              forM_ remaining $ \slot -> failSlot slot e
              forM_ allCmds $ \pc -> failSlot (pcSlot pc) e

-- Reader thread: pops response slots from the pending queue and fills
-- them with parsed RESP responses. When the buffer contains additional
-- data after parsing, batch-dequeues more slots and parses in a tight
-- inner loop to reduce per-response dequeue overhead.
-- Uses Attoparsec IResult directly to avoid Either allocation per response.
readerLoop
  :: PendingQueue
  -> IO ByteString
  -> IORef Bool
  -> IO ()
readerLoop pendingQueue recv alive = go BS.empty
  where
    go !buffer = do
      isAlive <- readIORef alive
      if not isAlive
        then return ()
        else do
          slot <- pendingDequeue pendingQueue
          feedParse slot (StrictParse.parse parseRespData buffer)

    -- Drive the incremental parser, feeding data until Done or Fail.
    -- Avoids allocating Either/tuple wrappers on the hot path.
    feedParse !slot (StrictParse.Done !remainder !resp) = do
      writeIORef (slotResult slot) (Just (Right resp))
      void $ tryPutMVar (slotSignal slot) ()
      -- If there's remaining data, try to parse more in a tight loop
      if BS.null remainder
        then go remainder
        else drainBuffer remainder
    feedParse !slot (StrictParse.Fail _ _ err) = do
      let !e = toException $ MultiplexerParseError err
      writeIORef (slotResult slot) (Just (Left e))
      void $ tryPutMVar (slotSignal slot) ()
      atomicWriteIORef alive False
      remaining <- pendingDrainAll pendingQueue
      forM_ remaining $ \s -> failSlot s e
    feedParse !slot (StrictParse.Partial cont) = do
      moreResult <- try recv
      case moreResult of
        Left (e :: SomeException) -> do
          writeIORef (slotResult slot) (Just (Left e))
          void $ tryPutMVar (slotSignal slot) ()
          atomicWriteIORef alive False
          remaining <- pendingDrainAll pendingQueue
          forM_ remaining $ \s -> failSlot s e
        Right moreData
          | BS.null moreData -> do
              let !e = toException MultiplexerConnectionClosed
              writeIORef (slotResult slot) (Just (Left e))
              void $ tryPutMVar (slotSignal slot) ()
              atomicWriteIORef alive False
              remaining <- pendingDrainAll pendingQueue
              forM_ remaining $ \s -> failSlot s e
          | otherwise -> feedParse slot (cont moreData)

    -- Tight inner loop: buffer has data, grab available slots and parse
    -- without blocking on empty queue. Falls back to outer loop when
    -- no more slots are available or buffer is exhausted.
    drainBuffer !buffer = do
      isAlive <- readIORef alive
      if not isAlive
        then return ()
        else do
          extraSlots <- pendingDequeueUpTo pendingQueue 128
          case Seq.viewl extraSlots of
            Seq.EmptyL -> go buffer  -- no slots ready, back to outer loop
            firstSlot Seq.:< restSlots ->
              fillSlots buffer firstSlot restSlots

    -- Parse and fill slots one at a time from the batch.
    -- Uses Attoparsec IResult directly (no Either wrapper).
    fillSlots !buffer !slot !remaining =
      feedParseBatch slot remaining (StrictParse.parse parseRespData buffer)

    feedParseBatch !slot !remaining (StrictParse.Done !remainder !resp) = do
      writeIORef (slotResult slot) (Just (Right resp))
      void $ tryPutMVar (slotSignal slot) ()
      case Seq.viewl remaining of
        Seq.EmptyL ->
          if BS.null remainder
            then go remainder
            else drainBuffer remainder
        nextSlot Seq.:< restSlots ->
          feedParseBatch nextSlot restSlots (StrictParse.parse parseRespData remainder)
    feedParseBatch !slot !remaining (StrictParse.Fail _ _ err) = do
      let !e = toException $ MultiplexerParseError err
      writeIORef (slotResult slot) (Just (Left e))
      void $ tryPutMVar (slotSignal slot) ()
      atomicWriteIORef alive False
      forM_ remaining $ \s -> failSlot s e
      queued <- pendingDrainAll pendingQueue
      forM_ queued $ \s -> failSlot s e
    feedParseBatch !slot !remaining (StrictParse.Partial cont) = do
      moreResult <- try recv
      case moreResult of
        Left (e :: SomeException) -> do
          writeIORef (slotResult slot) (Just (Left e))
          void $ tryPutMVar (slotSignal slot) ()
          atomicWriteIORef alive False
          forM_ remaining $ \s -> failSlot s e
          queued <- pendingDrainAll pendingQueue
          forM_ queued $ \s -> failSlot s e
        Right moreData
          | BS.null moreData -> do
              let !e = toException MultiplexerConnectionClosed
              writeIORef (slotResult slot) (Just (Left e))
              void $ tryPutMVar (slotSignal slot) ()
              atomicWriteIORef alive False
              forM_ remaining $ \s -> failSlot s e
              queued <- pendingDrainAll pendingQueue
              forM_ queued $ \s -> failSlot s e
          | otherwise -> feedParseBatch slot remaining (cont moreData)

-- | Fail a response slot with an exception.
failSlot :: ResponseSlot -> SomeException -> IO ()
failSlot slot e = do
  writeIORef (slotResult slot) (Just (Left e))
  void $ tryPutMVar (slotSignal slot) ()
{-# INLINE failSlot #-}

