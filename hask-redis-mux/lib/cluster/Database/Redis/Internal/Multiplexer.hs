{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

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
--
-- @since 0.1.0.0
module Database.Redis.Internal.Multiplexer
  ( Multiplexer
  , MultiplexerException (..)
  , SlotPool
  , ResponseSlot
  , createSlotPool
  , createMultiplexer
  , createMultiplexerFromConnector
  , createMultiplexerFromConnectorWithHandoffHook
  , submitCommand
  , submitCommandPooled
  , submitCommandNoResponsePooled
  , submitCommandPairPooled
  , submitCommandAsync
  , submitCommandNoResponseAsync
  , waitSlot
  , sameResponseSlot
  , destroyMultiplexer
  , isMultiplexerAlive
  ) where

import           Control.Concurrent               (ThreadId, forkIO,
                                                   forkIOWithUnmask, killThread,
                                                   myThreadId)
import           Control.Concurrent.MVar          (MVar, modifyMVar,
                                                   newEmptyMVar, newMVar,
                                                   putMVar, readMVar, takeMVar,
                                                   tryPutMVar, withMVar)
import           Control.Exception                (Exception, SomeException,
                                                   catch, finally, mask, mask_,
                                                   onException, throwIO,
                                                   toException, try,
                                                   uninterruptibleMask_)
import           Control.Monad                    (forM_, void, when)
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Builder.Extra    as Builder (toLazyByteStringWith,
                                                              untrimmedStrategy)
import qualified Data.ByteString.Lazy             as LBS
import           Data.IORef                       (IORef, atomicModifyIORef',
                                                   atomicWriteIORef, newIORef,
                                                   readIORef, writeIORef)
import           Data.List                        (foldl')
import           Data.Sequence                    (Seq)
import qualified Data.Sequence                    as Seq
import           Data.Typeable                    (Typeable)
import qualified Data.Vector                      as V
import           Database.Redis.Client            (Client (..),
                                                   ConnectionStatus (..))
import           Database.Redis.Cluster           (NodeAddress)
import           Database.Redis.Connector         (Connector)
import           Database.Redis.Resp              (RespData (..), parseRespData)
import qualified GHC.Conc                         as GHC (threadCapability)

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
  deriving Eq

-- | Test and diagnostics identity for a pooled response slot.
sameResponseSlot :: ResponseSlot -> ResponseSlot -> Bool
sameResponseSlot left right = slotSignal left == slotSignal right

-- | Striped pool of pre-allocated ResponseSlots.
-- Uses multiple IORef-based stacks indexed by capability (core) to reduce
-- CAS contention between threads on different cores.
data SlotPool = SlotPool
  { spStripes    :: !(V.Vector (IORef [ResponseSlot]))
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
  { pcBuilder         :: !Builder.Builder
  , pcExpectsResponse :: !Bool
  , pcSlot            :: !ResponseSlot
  }

-- | SPSC queue for pending response slots.
-- Writer is sole producer, reader is sole consumer.
-- Uses IORef + MVar signaling instead of STM TQueue.
data PendingQueue = PendingQueue
  { pqState  :: !(IORef PendingQueueState)
  , pqSignal :: !(MVar ())  -- signaled when new items are available
  }

data PendingQueueState = PendingQueueState
  { pqsQueued :: !(Seq ResponseSlot)
  , pqsActive :: !(Seq ResponseSlot)
  }

newPendingQueue :: IO PendingQueue
newPendingQueue = do
  state <- newIORef $ PendingQueueState Seq.empty Seq.empty
  signal <- newEmptyMVar
  return $ PendingQueue state signal

-- | Enqueue a Seq of response slots directly (avoids Seq.fromList conversion).
pendingEnqueueSeq :: PendingQueue -> Seq ResponseSlot -> IO ()
pendingEnqueueSeq pq newSlots = do
  atomicModifyIORef' (pqState pq) $ \state ->
    (state { pqsQueued = pqsQueued state <> newSlots }, ())
  void $ tryPutMVar (pqSignal pq) ()
{-# INLINE pendingEnqueueSeq #-}

-- | Dequeue one response slot (reader thread only — single consumer).
-- Blocks if empty.
pendingDequeue :: PendingQueue -> IO ResponseSlot
pendingDequeue pq = do
  mSlot <- atomicModifyIORef' (pqState pq) $ \state ->
    case Seq.viewl (pqsQueued state) of
      Seq.EmptyL -> (state, Nothing)
      slot Seq.:< rest ->
        ( state
            { pqsQueued = rest
            , pqsActive = pqsActive state Seq.|> slot
            }
        , Just slot
        )
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
  atomicModifyIORef' (pqState pq) $ \state ->
    let (taken, rest) = Seq.splitAt n (pqsQueued state)
    in ( state
           { pqsQueued = rest
           , pqsActive = pqsActive state <> taken
           }
       , taken
       )
{-# INLINE pendingDequeueUpTo #-}

-- | Remove the oldest reader-owned slot after it has been completed.
pendingCompleteOne :: PendingQueue -> IO ()
pendingCompleteOne pq =
  atomicModifyIORef' (pqState pq) $ \state ->
    case Seq.viewl (pqsActive state) of
      Seq.EmptyL    -> (state, ())
      _ Seq.:< rest -> (state { pqsActive = rest }, ())
{-# INLINE pendingCompleteOne #-}

-- | Drain all queued and reader-owned slots (for error propagation).
pendingDrainAll :: PendingQueue -> IO [ResponseSlot]
pendingDrainAll pq = do
  slots <- atomicModifyIORef' (pqState pq) $ \state ->
    let allSlots = pqsActive state <> pqsQueued state
    in (PendingQueueState Seq.empty Seq.empty, allSlots)
  return $ foldr (:) [] slots

-- | Lock-free MPSC (multi-producer, single-consumer) command queue.
-- Producers use atomicModifyIORef' to cons onto the list (single CAS).
-- The consumer reverses once per drain. MVar signals new item availability.
data CommandQueue = CommandQueue
  { cqState  :: !(IORef CommandQueueState)
  , cqSignal :: !(MVar ())                 -- wake writer when items available
  }

data CommandQueueState = CommandQueueState
  { cqsOpen   :: !Bool
  , cqsQueued :: ![PendingCommand] -- reverse order (newest first)
  , cqsActive :: ![PendingCommand] -- writer-owned batch, submission order
  }

newCommandQueue :: IO CommandQueue
newCommandQueue = do
  state  <- newIORef $ CommandQueueState True [] []
  signal <- newEmptyMVar
  return $ CommandQueue state signal

-- | Enqueue a command (caller thread — multi-producer safe).
-- Returns 'False' once teardown has closed admission.
commandEnqueue :: CommandQueue -> PendingCommand -> IO Bool
commandEnqueue cq pc = do
  accepted <- atomicModifyIORef' (cqState cq) $ \state ->
    if cqsOpen state
      then (state { cqsQueued = pc : cqsQueued state }, True)
      else (state, False)
  when accepted $ void $ tryPutMVar (cqSignal cq) ()
  return accepted
{-# INLINE commandEnqueue #-}

-- | Enqueue two commands atomically (caller thread — multi-producer safe).
-- Both commands are added in a single CAS so no other command can be
-- interleaved between them. The first command will appear before the second
-- in the pipeline.
commandEnqueuePair :: CommandQueue -> PendingCommand -> PendingCommand -> IO Bool
commandEnqueuePair cq pc1 pc2 = do
  accepted <- atomicModifyIORef' (cqState cq) $ \state ->
    if cqsOpen state
      then (state { cqsQueued = pc2 : pc1 : cqsQueued state }, True)
      else (state, False)
  when accepted $ void $ tryPutMVar (cqSignal cq) ()
  return accepted
{-# INLINE commandEnqueuePair #-}

-- | Drain all commands (writer thread only — single consumer).
-- Blocks if empty. Stale wakeups are retried while admission remains open;
-- an empty result is reserved for a closed queue. Returns commands in
-- submission order.
commandDrain :: CommandQueue -> IO [PendingCommand]
commandDrain cq = do
  takeMVar (cqSignal cq)
  result <- atomicModifyIORef' (cqState cq) $ \state ->
    case reverse (cqsQueued state) of
      []
        | cqsOpen state -> (state, Nothing)
        | otherwise     -> (state, Just [])
      batch ->
        (state { cqsQueued = [], cqsActive = batch }, Just batch)
  case result of
    Nothing    -> commandDrain cq
    Just batch -> return batch

-- | Non-blocking drain of any additional commands that have arrived.
-- Returns commands in submission order. Returns [] if none available.
commandTryDrain :: CommandQueue -> IO [PendingCommand]
commandTryDrain cq =
  atomicModifyIORef' (cqState cq) $ \state ->
    let batch = reverse (cqsQueued state)
    in ( state
           { cqsQueued = []
           , cqsActive = cqsActive state <> batch
           }
       , batch
       )

-- | Finish the masked handoff of the writer-owned batch to the pending queue.
commandBatchTransferred :: CommandQueue -> IO ()
commandBatchTransferred cq =
  atomicModifyIORef' (cqState cq) $ \state ->
    (state { cqsActive = [] }, ())
{-# INLINE commandBatchTransferred #-}

-- | Transfer only response-bearing commands to reader ownership. Commands
-- without a Redis response remain writer-owned until their send completes.
commandResponseSlotsTransferred :: CommandQueue -> IO ()
commandResponseSlotsTransferred cq =
  atomicModifyIORef' (cqState cq) $ \state ->
    (state { cqsActive = filter (not . pcExpectsResponse) (cqsActive state) }, ())
{-# INLINE commandResponseSlotsTransferred #-}

-- | Atomically stop accepting submissions. Returns whether this call closed it.
commandClose :: CommandQueue -> IO Bool
commandClose cq = do
  closed <- atomicModifyIORef' (cqState cq) $ \state ->
    if cqsOpen state
      then (state { cqsOpen = False }, True)
      else (state, False)
  void $ tryPutMVar (cqSignal cq) ()
  return closed

-- | Drain queued and writer-owned commands without blocking (for cleanup).
commandDrainAll :: CommandQueue -> IO [PendingCommand]
commandDrainAll cq =
  atomicModifyIORef' (cqState cq) $ \state ->
    let allCommands = cqsActive state <> reverse (cqsQueued state)
    in (state { cqsQueued = [], cqsActive = [] }, allCommands)

-- | A multiplexer wrapping a single Redis connection.
data Multiplexer = Multiplexer
  { muxCommandQueue :: !CommandQueue
  , muxPendingQueue :: !PendingQueue
  , muxWriterThread :: !ThreadId
  , muxReaderThread :: !ThreadId
  , muxWriterDone   :: !(MVar ())
  , muxReaderDone   :: !(MVar ())
  , muxAlive        :: !(IORef Bool)
  , muxLifecycle    :: !(IORef MultiplexerLifecycle)
  , muxDestroyLock  :: !(MVar ())
  , muxTransport    :: !TransportFinalizer
  }

data MultiplexerLifecycle
  = MultiplexerOpen
  | MultiplexerDestroying
  | MultiplexerDestroyed
  deriving (Eq)

-- | An exactly-once transport finalizer. Closing runs in its own thread so an
-- interrupted destroy caller cannot cancel the close action or invoke it twice.
data TransportFinalizer = TransportFinalizer
  { transportCloseAction :: !(IO ())
  , transportCloseState  :: !(MVar (Maybe (MVar (Either SomeException ()))))
  }

newTransportFinalizer :: IO () -> IO TransportFinalizer
newTransportFinalizer action =
  TransportFinalizer action <$> newMVar Nothing

startTransportClose :: TransportFinalizer -> IO (MVar (Either SomeException ()))
startTransportClose finalizer =
  modifyMVar (transportCloseState finalizer) $ \case
    Just done -> return (Just done, done)
    Nothing -> do
      done <- newEmptyMVar
      _ <- forkIOWithUnmask $ \unmask ->
        try (unmask $ transportCloseAction finalizer) >>= putMVar done
      return (Just done, done)

closeTransport :: TransportFinalizer -> IO ()
closeTransport finalizer = do
  done <- startTransportClose finalizer
  readMVar done >>= either throwIO return

-- | Create a multiplexer over an already-connected client.
--
-- Ownership of the connected transport transfers to the multiplexer. It is
-- closed exactly once by 'destroyMultiplexer', including partial construction
-- failure.
createMultiplexer
  :: (Client client)
  => client 'Connected
  -> IO ByteString       -- ^ Action to receive bytes from the connection
  -> IO Multiplexer
createMultiplexer conn recv = mask_ $ do
  transport <- newTransportFinalizer (close conn)
    `onException` (close conn `catch` \(_ :: SomeException) -> return ())
  build transport
    `onException` (closeTransport transport `catch` \(_ :: SomeException) -> return ())
  where
    build transport = do
      cmdQueue     <- newCommandQueue
      pendingQueue <- newPendingQueue
      transferLock <- newMVar ()
      alive        <- newIORef True
      lifecycle    <- newIORef MultiplexerOpen
      destroyLock  <- newMVar ()
      readerDone   <- newEmptyMVar
      writerDone   <- newEmptyMVar

      readerId <- forkIOWithUnmask $ \unmask ->
        unmask (readerLoop transferLock cmdQueue pendingQueue recv alive)
          `finally` putMVar readerDone ()
      writerId <- (forkIOWithUnmask $ \unmask ->
        unmask (writerLoop transferLock cmdQueue pendingQueue conn alive)
          `finally` putMVar writerDone ())
        `onException` do
          killThread readerId
          readMVar readerDone

      return $ Multiplexer
        cmdQueue pendingQueue writerId readerId writerDone readerDone
        alive lifecycle destroyLock transport

-- | Acquire a connected transport and transfer it to a multiplexer without an
-- asynchronous-exception gap between connector return and finalizer ownership.
createMultiplexerFromConnector
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> IO Multiplexer
createMultiplexerFromConnector connector addr =
  createMultiplexerFromConnectorWithHandoffHook
    connector addr (const $ return ())

-- | Variant with a masked handoff hook for deterministic lifecycle tests.
-- The hook runs after the connector returns but before finalizer installation.
createMultiplexerFromConnectorWithHandoffHook
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> (client 'Connected -> IO ())
  -> IO Multiplexer
createMultiplexerFromConnectorWithHandoffHook connector addr handoffHook =
  mask $ \restore -> do
    conn <- restore $ connector addr
    handoffHook conn
      `onException` (close conn `catch` \(_ :: SomeException) -> return ())
    createMultiplexer conn (receive conn)

multiplexerDestroyed :: SomeException
multiplexerDestroyed = toException $ MultiplexerDead "Multiplexer destroyed"

-- | Submit a pre-encoded RESP command as a Builder and block until the response arrives.
submitCommand :: Multiplexer -> Builder.Builder -> IO RespData
submitCommand mux cmdBuilder = do
  resultRef <- newIORef Nothing
  signal <- newEmptyMVar
  let slot = ResponseSlot resultRef signal
      pending = PendingCommand cmdBuilder True slot
  accepted <- commandEnqueue (muxCommandQueue mux) pending
  if accepted
    then do
      takeMVar signal
      mResult <- readIORef resultRef
      case mResult of
        Just (Right resp) -> return resp
        Just (Left e)     -> throwIO e
        Nothing           -> throwIO $ MultiplexerDead "Response slot empty after signal"
    else throwIO multiplexerDestroyed

-- | Like 'submitCommand', but acquires a 'ResponseSlot' from the pool
-- instead of allocating a fresh IORef+MVar per call.
submitCommandPooled :: SlotPool -> Multiplexer -> Builder.Builder -> IO RespData
submitCommandPooled pool mux cmdBuilder = mask $ \_ -> do
  slot <- acquireSlot pool
  let pending = PendingCommand cmdBuilder True slot
  accepted <- commandEnqueue (muxCommandQueue mux) pending
    `onException` releaseSlot pool slot
  if accepted
    then awaitSlotResult pool slot
    else do
      releaseSlot pool slot
      throwIO multiplexerDestroyed
{-# INLINE submitCommandPooled #-}

-- | Submit a command for which Redis intentionally sends no response.
--
-- The caller still waits until the writer has either sent the command or
-- failed it. Its slot is never made visible to the reader, so the next
-- server response remains paired with the next response-bearing command.
submitCommandNoResponsePooled :: SlotPool -> Multiplexer -> Builder.Builder -> IO ()
submitCommandNoResponsePooled pool mux cmdBuilder =
  void (submitCommandNoResponseAsync pool mux cmdBuilder >>= waitSlot pool)
{-# INLINE submitCommandNoResponsePooled #-}

-- | Submit two commands atomically as a pair. Both are enqueued in a single
-- atomic operation so no other command can be interleaved between them.
-- Returns only the second command's response; the first response is discarded.
-- Used for ASKING + command sequences where ASKING must immediately precede
-- the target command on the same connection.
submitCommandPairPooled :: SlotPool -> Multiplexer -> Builder.Builder -> Builder.Builder -> IO RespData
submitCommandPairPooled pool mux firstBuilder secondBuilder = mask $ \_ -> do
  slot1 <- acquireSlot pool
  slot2 <- acquireSlot pool `onException` releaseSlot pool slot1
  let pending1 = PendingCommand firstBuilder True slot1
      pending2 = PendingCommand secondBuilder True slot2
  accepted <- commandEnqueuePair (muxCommandQueue mux) pending1 pending2
    `onException` (releaseSlot pool slot1 >> releaseSlot pool slot2)
  if accepted
    then do
      -- Wait for and discard the first response (ASKING → +OK)
      void (awaitSlotResult pool slot1)
        `onException` releaseAfterSignal pool slot2
      -- Wait for the actual command response
      awaitSlotResult pool slot2
    else do
      releaseSlot pool slot1
      releaseSlot pool slot2
      throwIO multiplexerDestroyed
{-# INLINE submitCommandPairPooled #-}

-- | Submit a command asynchronously: enqueue it and return the ResponseSlot.
-- The caller must later call 'waitSlot' to get the result, then 'releaseSlot'.
submitCommandAsync :: SlotPool -> Multiplexer -> Builder.Builder -> IO ResponseSlot
submitCommandAsync pool mux cmdBuilder = mask $ \_ -> do
  slot <- acquireSlot pool
  let pending = PendingCommand cmdBuilder True slot
  accepted <- commandEnqueue (muxCommandQueue mux) pending
    `onException` releaseSlot pool slot
  if accepted
    then return slot
    else do
      releaseSlot pool slot
      throwIO multiplexerDestroyed
{-# INLINE submitCommandAsync #-}

-- | Asynchronously submit a command which intentionally has no Redis reply.
-- The returned slot is completed by the writer once the command has been
-- sent, or failed by transport teardown. It is never queued for the reader.
submitCommandNoResponseAsync :: SlotPool -> Multiplexer -> Builder.Builder -> IO ResponseSlot
submitCommandNoResponseAsync pool mux cmdBuilder = mask $ \_ -> do
  slot <- acquireSlot pool
  let pending = PendingCommand cmdBuilder False slot
  accepted <- commandEnqueue (muxCommandQueue mux) pending
    `onException` releaseSlot pool slot
  if accepted
    then return slot
    else do
      releaseSlot pool slot
      throwIO multiplexerDestroyed
{-# INLINE submitCommandNoResponseAsync #-}

-- | Wait for an async submission's result and release the slot back to the pool.
waitSlot :: SlotPool -> ResponseSlot -> IO RespData
waitSlot = awaitSlotResult
{-# INLINE waitSlot #-}

-- | The synchronous callers own their slot for the whole request. Cancellation
-- leaves a reaper responsible for returning it only after its completion.
awaitSlotResult :: SlotPool -> ResponseSlot -> IO RespData
awaitSlotResult pool slot = mask $ \restore -> do
  restore (takeMVar (slotSignal slot)) `onException` releaseAfterSignal pool slot
  mResult <- readIORef (slotResult slot)
  releaseSlot pool slot
  case mResult of
    Just (Right resp) -> return resp
    Just (Left e)     -> throwIO e
    Nothing           -> throwIO $ MultiplexerDead "Response slot empty after signal"

releaseAfterSignal :: SlotPool -> ResponseSlot -> IO ()
releaseAfterSignal pool slot = do
  _ <- forkIO $ mask_ $ do
    takeMVar (slotSignal slot)
    releaseSlot pool slot
  return ()

-- | Tear down the multiplexer: kill both threads and fail all pending commands.
destroyMultiplexer :: Multiplexer -> IO ()
destroyMultiplexer mux =
  withMVar (muxDestroyLock mux) $ \() -> mask_ $ do
    lifecycle <- readIORef (muxLifecycle mux)
    when (lifecycle /= MultiplexerDestroyed) $ do
      when (lifecycle == MultiplexerOpen) $ do
        writeIORef (muxLifecycle mux) MultiplexerDestroying
        void $ commandClose (muxCommandQueue mux)
        atomicWriteIORef (muxAlive mux) False

      transportDone <- startTransportClose (muxTransport mux)

      -- These operations may block and remain interruptible. If this owner is
      -- cancelled, the Destroying state lets the next caller resume teardown.
      killThread (muxWriterThread mux)
      killThread (muxReaderThread mux)
      readMVar (muxWriterDone mux)
      readMVar (muxReaderDone mux)
      transportResult <- readMVar transportDone

      -- Queue drains and slot completion are bounded, non-blocking operations.
      -- Keeping this tail uninterruptible prevents ownership from being lost
      -- between removing a slot from lifecycle tracking and signaling it.
      uninterruptibleMask_ $ do
        commands <- commandDrainAll (muxCommandQueue mux)
        pending <- pendingDrainAll (muxPendingQueue mux)
        forM_ commands $ \pc -> failSlot (pcSlot pc) multiplexerDestroyed
        forM_ pending $ \slot -> failSlot slot multiplexerDestroyed
        writeIORef (muxLifecycle mux) MultiplexerDestroyed

      either throwIO return transportResult

-- | Check if the multiplexer's threads are still running.
isMultiplexerAlive :: Multiplexer -> IO Bool
isMultiplexerAlive = readIORef . muxAlive

-- Writer thread: drains command queue, pushes response slots onto pending
-- queue (in IO, not STM), and sends batched bytes over the wire.
writerLoop
  :: (Client client)
  => MVar ()
  -> CommandQueue
  -> PendingQueue
  -> client 'Connected
  -> IORef Bool
  -> IO ()
writerLoop transferLock cmdQueue pendingQueue conn alive = go
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

          if null allCmds
            then return ()
            else do
              -- No-response slots remain writer-owned until send succeeds;
              -- response slots transfer to the reader in pipeline order.
              let (!responseSlots, !noResponseSlots, !builder) = foldl'
                    (\(!responseAcc, !noResponseAcc, !builderAcc) pc ->
                      ( if pcExpectsResponse pc
                          then responseAcc Seq.|> pcSlot pc
                          else responseAcc
                      , if pcExpectsResponse pc
                          then noResponseAcc
                          else noResponseAcc Seq.|> pcSlot pc
                      , builderAcc <> pcBuilder pc
                      ))
                    (Seq.empty, Seq.empty, mempty)
                    allCmds

              transferred <- withMVar transferLock $ \() -> mask_ $ do
                stillAlive <- readIORef alive
                when stillAlive $ do
                  commandResponseSlotsTransferred cmdQueue
                  pendingEnqueueSeq pendingQueue responseSlots
                return stillAlive

              when transferred $ do
                -- Materialize with large buffer strategy and send via vectored I/O.
                -- untrimmedStrategy avoids trimming/copying the final chunk.
                -- 32KB initial / 64KB growth reduces chunk count vs default 4KB.
                -- sendChunks uses writev(2) for zero-copy vectored I/O on plain sockets.
                let !lbs = Builder.toLazyByteStringWith
                             (Builder.untrimmedStrategy 32768 65536) LBS.empty builder
                    !chunks = LBS.toChunks lbs
                result <- try $ sendChunks conn chunks
                case result of
                  Right () -> do
                    uninterruptibleMask_ $ do
                      forM_ noResponseSlots $ \slot ->
                        void $ completeSlot slot (Right (RespSimpleString "OK"))
                      commandBatchTransferred cmdQueue
                    go
                  Left (e :: SomeException) ->
                    failMultiplexerQueues transferLock cmdQueue pendingQueue alive e

-- Reader thread: pops response slots from the pending queue and fills
-- them with parsed RESP responses. When the buffer contains additional
-- data after parsing, batch-dequeues more slots and parses in a tight
-- inner loop to reduce per-response dequeue overhead.
-- Uses Attoparsec IResult directly to avoid Either allocation per response.
readerLoop
  :: MVar ()
  -> CommandQueue
  -> PendingQueue
  -> IO ByteString
  -> IORef Bool
  -> IO ()
readerLoop transferLock cmdQueue pendingQueue recv alive = go BS.empty
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
      completePendingSlot pendingQueue slot (Right resp)
      -- If there's remaining data, try to parse more in a tight loop
      if BS.null remainder
        then go remainder
        else drainBuffer remainder
    feedParse !_slot (StrictParse.Fail _ _ err) = do
      let !e = toException $ MultiplexerParseError err
      failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
    feedParse !slot (StrictParse.Partial cont) = do
      moreResult <- try recv
      case moreResult of
        Left (e :: SomeException) ->
          failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
        Right moreData
          | BS.null moreData -> do
              let !e = toException MultiplexerConnectionClosed
              failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
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
      completePendingSlot pendingQueue slot (Right resp)
      case Seq.viewl remaining of
        Seq.EmptyL ->
          if BS.null remainder
            then go remainder
            else drainBuffer remainder
        nextSlot Seq.:< restSlots ->
          feedParseBatch nextSlot restSlots (StrictParse.parse parseRespData remainder)
    feedParseBatch !_slot !_remaining (StrictParse.Fail _ _ err) = do
      let !e = toException $ MultiplexerParseError err
      failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
    feedParseBatch !slot !remaining (StrictParse.Partial cont) = do
      moreResult <- try recv
      case moreResult of
        Left (e :: SomeException) ->
          failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
        Right moreData
          | BS.null moreData -> do
              let !e = toException MultiplexerConnectionClosed
              failMultiplexerQueues transferLock cmdQueue pendingQueue alive e
          | otherwise -> feedParseBatch slot remaining (cont moreData)

-- | Remove a reader-owned slot from lifecycle tracking and complete it without
-- allowing teardown to interrupt the handoff between those two operations.
completePendingSlot
  :: PendingQueue
  -> ResponseSlot
  -> Either SomeException RespData
  -> IO ()
completePendingSlot pendingQueue slot result = mask_ $ do
  pendingCompleteOne pendingQueue
  void $ completeSlot slot result
{-# INLINE completePendingSlot #-}

-- | Close admission and fail every slot still owned by either worker queue.
failMultiplexerQueues
  :: MVar ()
  -> CommandQueue
  -> PendingQueue
  -> IORef Bool
  -> SomeException
  -> IO ()
failMultiplexerQueues transferLock cmdQueue pendingQueue alive e =
  withMVar transferLock $ \() -> mask_ $ do
    wasAlive <- readIORef alive
    let failure = if wasAlive then e else multiplexerDestroyed
    atomicWriteIORef alive False
    void $ commandClose cmdQueue
    commands <- commandDrainAll cmdQueue
    pending <- pendingDrainAll pendingQueue
    forM_ commands $ \pc -> failSlot (pcSlot pc) failure
    forM_ pending $ \slot -> failSlot slot failure

-- | Complete a response slot at most once. The result and wakeup are owned by
-- the thread that wins the atomic transition from 'Nothing'.
completeSlot :: ResponseSlot -> Either SomeException RespData -> IO Bool
completeSlot slot result = do
  completed <- atomicModifyIORef' (slotResult slot) $ \current ->
    case current of
      Nothing -> (Just result, True)
      Just _  -> (current, False)
  when completed $ void $ tryPutMVar (slotSignal slot) ()
  return completed
{-# INLINE completeSlot #-}

-- | Fail a response slot with an exception.
failSlot :: ResponseSlot -> SomeException -> IO ()
failSlot slot e =
  void $ completeSlot slot (Left e)
{-# INLINE failSlot #-}
