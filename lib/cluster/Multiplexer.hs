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
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TQueue
  , atomically
  , flushTBQueue
  , newTBQueueIO
  , newTQueueIO
  , orElse
  , readTBQueue
  , readTQueue
  , writeTBQueue
  , writeTQueue
  )
import Control.Exception
  ( Exception
  , SomeException
  , catch
  , mask_
  , throwIO
  , toException
  , try
  )
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import Data.IORef (IORef, newIORef, readIORef, atomicWriteIORef)
import Data.Typeable (Typeable)
import Resp (RespData, parseRespData)

import Numeric.Natural (Natural)

-- | Exception thrown when submitting to a dead multiplexer.
data MultiplexerException
  = MultiplexerDead String
  | MultiplexerParseError String
  | MultiplexerConnectionClosed
  deriving (Show, Typeable)

instance Exception MultiplexerException

-- | A command waiting to be sent, paired with a one-shot response slot.
data PendingCommand = PendingCommand
  { pcBuilder  :: !Builder.Builder
  , pcResponse :: !(MVar (Either SomeException RespData))
  }

-- | A multiplexer wrapping a single Redis connection.
-- The writer thread batches commands from the queue and sends them;
-- the reader thread parses responses and dispatches to callers in order.
data Multiplexer = Multiplexer
  { muxCommandQueue :: !(TBQueue PendingCommand)
  , muxWriterThread :: !ThreadId
  , muxReaderThread :: !ThreadId
  , muxAlive        :: !(IORef Bool)
  }

-- | Default command queue capacity (backpressure threshold).
defaultQueueCapacity :: Natural
defaultQueueCapacity = 4096

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
  cmdQueue     <- newTBQueueIO defaultQueueCapacity
  pendingQueue <- newTQueueIO
  alive        <- newIORef True

  readerId <- forkIO $ readerLoop pendingQueue recv alive
  writerId <- forkIO $ writerLoop cmdQueue pendingQueue conn alive readerId

  return $ Multiplexer cmdQueue writerId readerId alive

-- | Submit a pre-encoded RESP command as a Builder and block until the response arrives.
-- Throws 'MultiplexerDead' if the multiplexer has been destroyed or its
-- connection has failed.
submitCommand :: Multiplexer -> Builder.Builder -> IO RespData
submitCommand mux cmdBuilder = do
  isAlive <- readIORef (muxAlive mux)
  if not isAlive
    then throwIO $ MultiplexerDead "Multiplexer is not alive"
    else do
      responseMVar <- newEmptyMVar
      let pending = PendingCommand cmdBuilder responseMVar
      atomically $ writeTBQueue (muxCommandQueue mux) pending
      result <- readMVar responseMVar
      either throwIO return result

-- | Tear down the multiplexer: kill both threads and fail all pending commands.
destroyMultiplexer :: Multiplexer -> IO ()
destroyMultiplexer mux = mask_ $ do
  atomicWriteIORef (muxAlive mux) False
  killThread (muxWriterThread mux)
  killThread (muxReaderThread mux)
  -- Drain any remaining commands and fail them
  remaining <- atomically $ flushTBQueue (muxCommandQueue mux)
  let err = MultiplexerDead "Multiplexer destroyed"
  forM_ remaining $ \pc ->
    putMVar (pcResponse pc) (Left $ toException err)

-- | Check if the multiplexer's threads are still running.
isMultiplexerAlive :: Multiplexer -> IO Bool
isMultiplexerAlive = readIORef . muxAlive

-- Writer thread: drains command queue, pushes response MVars onto pending
-- queue (preserving send order), and sends batched bytes over the wire.
writerLoop
  :: (Client client)
  => TBQueue PendingCommand
  -> TQueue (MVar (Either SomeException RespData))
  -> client 'Connected
  -> IORef Bool
  -> ThreadId  -- ^ Reader thread ID, killed on writer failure
  -> IO ()
writerLoop cmdQueue pendingQueue conn alive readerId = go
  where
    go = do
      -- Block until at least one command, then drain all available.
      -- Push response MVars onto pending queue in send order within
      -- the same STM transaction to reduce overhead.
      batch <- atomically $ do
        first <- readTBQueue cmdQueue
        rest  <- flushTBQueue cmdQueue
        let batch = first : rest
        forM_ batch $ \pc ->
          writeTQueue pendingQueue (pcResponse pc)
        return batch

      -- Batch-materialize all builders into a single lazy ByteString and send
      let allBytes = Builder.toLazyByteString $ foldMap pcBuilder batch
      result <- try $ send conn allBytes
      case result of
        Right () -> go
        Left (e :: SomeException) -> do
          atomicWriteIORef alive False
          killThread readerId
          failPending pendingQueue e
          failBatch batch e

-- Reader thread: pops response MVars from the pending queue and fills
-- them with parsed RESP responses, one at a time.
readerLoop
  :: TQueue (MVar (Either SomeException RespData))
  -> IO ByteString
  -> IORef Bool
  -> IO ()
readerLoop pendingQueue recv alive = go BS.empty
  where
    go !buffer = do
      -- Block until a response MVar is available
      responseMVar <- atomically $ readTQueue pendingQueue

      -- Parse one RespData from socket, using buffer for leftovers
      parseResult <- parseOneResp buffer recv
      case parseResult of
        Right (resp, remainder) -> do
          putMVar responseMVar (Right resp)
          go remainder
        Left e -> do
          putMVar responseMVar (Left e)
          atomicWriteIORef alive False
          -- Fail all remaining pending responses
          failPending pendingQueue e

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

-- | Drain the pending queue and fail all waiting callers.
failPending :: TQueue (MVar (Either SomeException RespData)) -> SomeException -> IO ()
failPending pendingQueue e = do
  remaining <- atomically $ flushTQueue pendingQueue
  forM_ remaining $ \mvar ->
    putMVar mvar (Left e) `catch` \(_ :: SomeException) -> return ()

-- | Drain all items from a TQueue (STM transaction, non-blocking).
flushTQueue :: TQueue a -> STM [a]
flushTQueue q = go' []
  where
    go' acc = do
      mItem <- (Just <$> readTQueue q) `orElse` return Nothing
      case mItem of
        Nothing   -> return (reverse acc)
        Just item -> go' (item : acc)

-- | Fail all commands in a batch that haven't been dispatched yet.
failBatch :: [PendingCommand] -> SomeException -> IO ()
failBatch batch e =
  forM_ batch $ \pc ->
    putMVar (pcResponse pc) (Left e) `catch` \(_ :: SomeException) -> return ()
