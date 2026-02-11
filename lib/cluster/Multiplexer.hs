{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

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
  , createMultiplexer
  , submitCommand
  , destroyMultiplexer
  , isMultiplexerAlive
  ) where

import Client (Client (..), ConnectionStatus (..))
import Control.Concurrent (ThreadId, forkIO, killThread)
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
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicWriteIORef, atomicModifyIORef')
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
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

-- | Enqueue response slots (writer thread only — single producer).
pendingEnqueue :: PendingQueue -> [ResponseSlot] -> IO ()
pendingEnqueue pq newSlots = do
  atomicModifyIORef' (pqSlots pq) $ \s ->
    (s <> Seq.fromList newSlots, ())
  void $ tryPutMVar (pqSignal pq) ()

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

-- | Drain all commands (writer thread only — single consumer).
-- Blocks if empty. Returns commands in submission order.
commandDrain :: CommandQueue -> IO [PendingCommand]
commandDrain cq = do
  takeMVar (cqSignal cq)
  batch <- atomicModifyIORef' (cqItems cq) $ \xs -> ([], xs)
  return (reverse batch)

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

          -- Push response slots to pending queue in IO (not STM — SPSC safe)
          pendingEnqueue pendingQueue (map pcSlot batch)

          -- Batch-materialize and send
          let allBytes = Builder.toLazyByteString $ foldMap pcBuilder batch
          result <- try $ send conn allBytes
          case result of
            Right () -> go
            Left (e :: SomeException) -> do
              atomicWriteIORef alive False
              remaining <- pendingDrainAll pendingQueue
              forM_ remaining $ \slot -> failSlot slot e
              forM_ batch $ \pc -> failSlot (pcSlot pc) e

-- Reader thread: pops response slots from the pending queue and fills
-- them with parsed RESP responses, one at a time.
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

          parseResult <- parseOneResp buffer recv
          case parseResult of
            Right (resp, remainder) -> do
              writeIORef (slotResult slot) (Just (Right resp))
              void $ tryPutMVar (slotSignal slot) ()
              go remainder
            Left e -> do
              writeIORef (slotResult slot) (Just (Left e))
              void $ tryPutMVar (slotSignal slot) ()
              atomicWriteIORef alive False
              remaining <- pendingDrainAll pendingQueue
              forM_ remaining $ \s -> failSlot s e

-- | Parse exactly one RESP value from the buffer + socket.
parseOneResp
  :: ByteString
  -> IO ByteString
  -> IO (Either SomeException (RespData, ByteString))
parseOneResp buffer recv = go' (StrictParse.parse parseRespData buffer)
  where
    go' (StrictParse.Done remainder resp) = return $ Right (resp, remainder)
    go' (StrictParse.Fail _ _ err) =
      return $ Left $ toException $ MultiplexerParseError err
    go' (StrictParse.Partial cont) = do
      moreResult <- try recv
      case moreResult of
        Left (e :: SomeException) -> return $ Left e
        Right moreData
          | BS.null moreData ->
              return $ Left $ toException MultiplexerConnectionClosed
          | otherwise -> go' (cont moreData)

-- | Fail a response slot with an exception.
failSlot :: ResponseSlot -> SomeException -> IO ()
failSlot slot e = do
  writeIORef (slotResult slot) (Just (Left e))
  void $ tryPutMVar (slotSignal slot) ()

