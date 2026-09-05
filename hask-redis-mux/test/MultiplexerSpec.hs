{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent                  (forkFinally, forkIO,
                                                      forkOn, killThread,
                                                      threadDelay)
import           Control.Concurrent.MVar             (MVar, newEmptyMVar,
                                                      putMVar, takeMVar,
                                                      tryPutMVar)
import           Control.Exception                   (AsyncException (ThreadKilled),
                                                      SomeException,
                                                      fromException, throwIO,
                                                      try, uninterruptibleMask_)
import           Control.Monad                       (replicateM, replicateM_,
                                                      void)
import           Control.Monad.IO.Class              (liftIO)
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString                     as BS
import qualified Data.ByteString.Builder             as Builder
import qualified Data.ByteString.Lazy                as LBS
import           Data.IORef                          (IORef, atomicModifyIORef',
                                                      newIORef, readIORef)
import           Data.List                           (sort)
import           Database.Redis.Client               (Client (..),
                                                      ConnectionStatus (..))
import           Database.Redis.Cluster              (NodeAddress (..))
import           Database.Redis.Internal.Multiplexer
import           Database.Redis.Resp                 (Encodable (..),
                                                      RespData (..))
import           System.Timeout                      (timeout)
import           Test.Hspec

-- ---------------------------------------------------------------------------
-- Mock client for testing without a real Redis connection
-- ---------------------------------------------------------------------------

-- | A mock client that uses IORef-based queues for send/receive.
-- Sent data is accumulated in sendBuf; recv reads from recvBuf.
data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef ByteString)  -- sendBuf (accumulates sent data)
                -> !(IORef [ByteString]) -- recvQueue (list of chunks to return)
                -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close _ = return ()
  send (MockConnected sendBuf _) lbs = liftIO $ do
    let !bs = LBS.toStrict lbs
    atomicModifyIORef' sendBuf $ \old -> (old <> bs, ())
  receive (MockConnected sRef recvQueue) = liftIO $ recvLoop sRef recvQueue

-- | Polling recv loop — retries until data is available.
recvLoop :: IORef ByteString -> IORef [ByteString] -> IO ByteString
recvLoop sRef recvQueue = do
  mChunk <- atomicModifyIORef' recvQueue $ \xs ->
    case xs of
      []     -> ([], Nothing)
      (y:ys) -> (ys, Just y)
  case mChunk of
    Just chunk -> return chunk
    Nothing -> do
      threadDelay 1000
      recvLoop sRef recvQueue

-- | Create a mock client and return (client, addRecvData).
-- addRecvData pushes response bytes that the reader thread will consume.
createMockClient :: IO (MockClient 'Connected, ByteString -> IO ())
createMockClient = do
  sendBuf <- newIORef BS.empty
  recvQueue <- newIORef []
  let client = MockConnected sendBuf recvQueue
      addRecv bs = atomicModifyIORef' recvQueue $ \xs -> (xs ++ [bs], ())
  return (client, addRecv)

-- | Transport that confirms the writer reached 'send' and then withholds all
-- responses. This lets lifecycle tests deterministically destroy a mux after
-- its first slot has moved from the command queue to the pending queue.
data BlockingClient (a :: ConnectionStatus) where
  BlockingConnected :: !(MVar ()) -> !(MVar ByteString) -> BlockingClient 'Connected

instance Client BlockingClient where
  connect = error "BlockingClient: connect not supported"
  close _ = return ()
  send (BlockingConnected sent _) _ =
    liftIO $ void $ tryPutMVar sent ()
  receive (BlockingConnected _ replies) =
    liftIO $ takeMVar replies

createBlockingClient :: IO (BlockingClient 'Connected, IO (), ByteString -> IO ())
createBlockingClient = do
  sent <- newEmptyMVar
  replies <- newEmptyMVar
  let awaitSend = do
        observed <- timeout 1000000 (takeMVar sent)
        observed `shouldBe` Just ()
      reply = putMVar replies
  return (BlockingConnected sent replies, awaitSend, reply)

-- | Transport with a reader-owned first slot, a pending second slot whose send
-- is uninterruptibly gated, and a blocked writer that leaves later submissions
-- queued. It exposes deterministic lifecycle barriers for teardown tests.
data TeardownClient (a :: ConnectionStatus) where
  TeardownConnected
    :: !(IORef Int)
    -> !(MVar ())
    -> !(MVar ())
    -> !(MVar ())
    -> !(MVar ())
    -> !(MVar ByteString)
    -> !(MVar ())
    -> !(MVar ())
    -> TeardownClient 'Connected

instance Client TeardownClient where
  connect = error "TeardownClient: connect not supported"
  close (TeardownConnected _ _ _ _ _ _ closeStarted releaseClose) =
    liftIO $ do
      void $ tryPutMVar closeStarted ()
      takeMVar releaseClose
  send (TeardownConnected sendCount firstSent secondSendGated releaseSecond _ _ _ _) _ =
    liftIO $ do
      sendNumber <- atomicModifyIORef' sendCount $ \count ->
        let next = count + 1
        in (next, next)
      case sendNumber of
        1 -> void $ tryPutMVar firstSent ()
        2 -> uninterruptibleMask_ $ do
          void $ tryPutMVar secondSendGated ()
          takeMVar releaseSecond
        _ -> return ()
  receive (TeardownConnected _ _ _ _ receiveStarted replies _ _) =
    liftIO $ do
      void $ tryPutMVar receiveStarted ()
      takeMVar replies

createTeardownClient
  :: IO
       ( TeardownClient 'Connected
       , IO ()
       , IO ()
       , IO ()
       , IO ()
       , IO ()
       , IO ()
       )
createTeardownClient = do
  sendCount <- newIORef 0
  firstSent <- newEmptyMVar
  secondSendGated <- newEmptyMVar
  releaseSecond <- newEmptyMVar
  receiveStarted <- newEmptyMVar
  replies <- newEmptyMVar
  closeStarted <- newEmptyMVar
  releaseClose <- newEmptyMVar
  let await barrier = do
        observed <- timeout 1000000 (takeMVar barrier)
        observed `shouldBe` Just ()
  return
    ( TeardownConnected
        sendCount firstSent secondSendGated releaseSecond receiveStarted replies
        closeStarted releaseClose
    , await firstSent
    , await secondSendGated
    , await receiveStarted
    , putMVar releaseSecond ()
    , await closeStarted
    , putMVar releaseClose ()
    )

data AcquisitionClient (a :: ConnectionStatus) where
  AcquisitionConnected
    :: !(IORef Int)
    -> !(IORef Int)
    -> !(MVar ByteString)
    -> AcquisitionClient 'Connected

instance Client AcquisitionClient where
  connect = error "AcquisitionClient: connect not supported"
  close (AcquisitionConnected closeCount _ _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send (AcquisitionConnected _ workerStarts _) _ =
    liftIO $ atomicModifyIORef' workerStarts $ \count -> (count + 1, ())
  receive (AcquisitionConnected _ workerStarts replies) = liftIO $ do
    atomicModifyIORef' workerStarts $ \count -> (count + 1, ())
    takeMVar replies

data ClosingClient (a :: ConnectionStatus) where
  ClosingConnected
    :: !(IORef Int)
    -> !(MVar ())
    -> !(MVar ())
    -> !(MVar ByteString)
    -> ClosingClient 'Connected

instance Client ClosingClient where
  connect = error "ClosingClient: connect not supported"
  close (ClosingConnected closeCount closeStarted releaseClose _) = liftIO $ do
    atomicModifyIORef' closeCount $ \count -> (count + 1, ())
    void $ tryPutMVar closeStarted ()
    takeMVar releaseClose
  send _ _ = return ()
  receive (ClosingConnected _ _ _ replies) = liftIO $ takeMVar replies

-- | Encode a RespData to strict ByteString (for feeding to mock recv).
encodeResp :: RespData -> ByteString
encodeResp = LBS.toStrict . Builder.toLazyByteString . encode

-- | Encode a RESP command as a Builder (for submitting to multiplexer).
encodeCmd :: [ByteString] -> Builder.Builder
encodeCmd args =
  Builder.byteString ("*" <> bshow (length args) <> "\r\n")
  <> foldMap (\a -> Builder.byteString ("$" <> bshow (BS.length a) <> "\r\n" <> a <> "\r\n")) args
  where bshow x = LBS.toStrict (Builder.toLazyByteString (Builder.intDec x))

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  slotPoolSpec
  responseSlotSpec
  commandQueueBatchingSpec
  multiplexerLifecycleSpec
  isMultiplexerAliveSpec

slotPoolSpec :: Spec
slotPoolSpec = describe "SlotPool" $ do
  it "allocation returns a valid slot" $ do
    pool <- createSlotPool 64
    -- acquireSlot is not exported, but submitCommandPooled uses it internally.
    -- We test via the public API: create multiplexer, submit, verify response.
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "OK"))
    resp <- submitCommandPooled pool mux (encodeCmd ["PING"])
    resp `shouldBe` RespSimpleString "OK"
    destroyMultiplexer mux

  it "slots are reusable (return-and-reuse)" $ do
    pool <- createSlotPool 4
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit multiple commands sequentially — slots should be reused from pool
    let n = 20
    mapM_ (\i -> do
      addRecv (encodeResp (RespInteger i))
      resp <- submitCommandPooled pool mux (encodeCmd ["GET", "key"])
      resp `shouldBe` RespInteger i
      ) [1..n]
    destroyMultiplexer mux

  it "striped distribution across cores does not crash" $ do
    -- Verify that pool creation with various sizes works
    pool1 <- createSlotPool 1
    pool2 <- createSlotPool 16
    pool3 <- createSlotPool 1024
    -- Use each pool to ensure stripes are functional
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool1 mux (encodeCmd ["PING"])
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool2 mux (encodeCmd ["PING"])
    addRecv (encodeResp (RespSimpleString "OK"))
    _ <- submitCommandPooled pool3 mux (encodeCmd ["PING"])
    destroyMultiplexer mux

responseSlotSpec :: Spec
responseSlotSpec = describe "ResponseSlot" $ do
  it "write-then-read returns correct value" $ do
    pool <- createSlotPool 16
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit a command; the reader thread writes the response to the slot
    addRecv (encodeResp (RespBulkString "hello"))
    resp <- submitCommandPooled pool mux (encodeCmd ["GET", "key"])
    resp `shouldBe` RespBulkString "hello"
    destroyMultiplexer mux

  it "waitSlot blocks until filled (async submit)" $ do
    pool <- createSlotPool 16
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Submit async — slot should not be filled yet
    slot <- submitCommandAsync pool mux (encodeCmd ["GET", "key"])
    -- Feed response after a short delay
    _ <- forkIO $ do
      threadDelay 50000  -- 50ms delay
      addRecv (encodeResp (RespBulkString "delayed"))
    resp <- waitSlot pool slot
    resp `shouldBe` RespBulkString "delayed"
    destroyMultiplexer mux

commandQueueBatchingSpec :: Spec
commandQueueBatchingSpec = describe "Command queue batching" $ do
  it "multiple enqueued commands are drained together" $ do
    pool <- createSlotPool 64
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)

    -- Submit 5 commands concurrently, then feed 5 responses
    let n = 5
    results <- newIORef ([] :: [RespData])
    barriers <- mapM (\_ -> newEmptyMVar) [1..n]

    -- Submit commands from separate threads
    mapM_ (\(i, barrier) -> forkIO $ do
      resp <- submitCommandPooled pool mux (encodeCmd ["GET", LBS.toStrict $ Builder.toLazyByteString $ Builder.intDec i])
      atomicModifyIORef' results $ \rs -> (rs ++ [resp], ())
      putMVar barrier ()
      ) (zip [1..n] barriers)

    -- Give commands time to be enqueued
    threadDelay 10000

    -- Feed all responses at once (they should be batched)
    let allResponses = mconcat $ map (\i -> encodeResp (RespInteger (fromIntegral (i :: Int)))) [1..n]
    addRecv allResponses

    -- Wait for all to complete
    mapM_ takeMVar barriers

    -- Verify all responses received
    rs <- readIORef results
    length rs `shouldBe` n
    destroyMultiplexer mux

  it "consumes concatenated response frames from the parser remainder" $ do
    pool <- createSlotPool 2
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    firstSlot <- submitCommandAsync pool mux (encodeCmd ["PING"])
    secondSlot <- submitCommandAsync pool mux (encodeCmd ["GET", "key"])

    addRecv $ encodeResp (RespSimpleString "PONG") <> encodeResp (RespInteger 1)

    first <- timeout 1000000 (waitSlot pool firstSlot)
    second <- timeout 1000000 (waitSlot pool secondSlot)
    first `shouldBe` Just (RespSimpleString "PONG")
    second `shouldBe` Just (RespInteger 1)
    destroyMultiplexer mux

  it "fails promptly when a response has a malformed CRLF delimiter" $ do
    pool <- createSlotPool 1
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    slot <- submitCommandAsync pool mux (encodeCmd ["PING"])

    addRecv "+OK\rX"

    result <- timeout 1000000
      (try (waitSlot pool slot) :: IO (Either SomeException RespData))
    result `shouldSatisfy` isTimedMultiplexerParseFailure
    destroyMultiplexer mux

multiplexerLifecycleSpec :: Spec
multiplexerLifecycleSpec = describe "Multiplexer lifecycle" $ do
  it "create and submit returns correct response" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespSimpleString "PONG"))
    resp <- submitCommand mux (encodeCmd ["PING"])
    resp `shouldBe` RespSimpleString "PONG"
    destroyMultiplexer mux

  it "destroy then submit throws MultiplexerDead" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    -- Small delay for destroy to take effect
    threadDelay 10000
    result <- try $ submitCommand mux (encodeCmd ["PING"])
    case result of
      Left (e :: SomeException) -> show e `shouldContain` "MultiplexerDead"
      Right _ -> expectationFailure "Expected MultiplexerDead exception"

  mapM_ (\transportName ->
    it ("closes a returned " <> transportName <> " transport cancelled before finalizer installation") $ do
      closeCount <- newIORef 0
      workerStarts <- newIORef 0
      replies <- newEmptyMVar
      handoffStarted <- newEmptyMVar
      releaseHandoff <- newEmptyMVar
      let client = AcquisitionConnected closeCount workerStarts replies
          connector _ = return client
          handoffHook _ = putMVar handoffStarted () >> takeMVar releaseHandoff

      finished <- newEmptyMVar
      owner <- forkFinally
        (createMultiplexerFromConnectorWithHandoffHook
          connector (NodeAddress "127.0.0.1" 6379) handoffHook)
        (putMVar finished)
      timeout 1000000 (takeMVar handoffStarted) `shouldReturn` Just ()
      killThread owner
      outcome <- timeout 1000000 (takeMVar finished)
      case outcome of
        Just (Left _) -> return ()
        _             -> expectationFailure "handoff cancellation did not terminate creation"
      readIORef closeCount `shouldReturn` 1
      readIORef workerStarts `shouldReturn` 0
    ) ["plaintext", "TLS"]

  it "closes the owned transport exactly once when the destroy owner is cancelled" $ do
    closeCount <- newIORef 0
    closeStarted <- newEmptyMVar
    releaseClose <- newEmptyMVar
    replies <- newEmptyMVar
    let client = ClosingConnected closeCount closeStarted releaseClose replies
    mux <- createMultiplexer client (receive client)

    ownerDone <- newEmptyMVar
    owner <- forkFinally (destroyMultiplexer mux) (putMVar ownerDone)
    started <- timeout 1000000 (takeMVar closeStarted)
    started `shouldBe` Just ()
    killThread owner
    cancelled <- timeout 1000000 (takeMVar ownerDone)
    cancelled `shouldSatisfy` \case
      Just (Left _) -> True
      _             -> False

    putMVar releaseClose ()
    resumed <- timeout 1000000 (destroyMultiplexer mux)
    resumed `shouldBe` Just ()
    replicateM_ 3 (destroyMultiplexer mux)
    readIORef closeCount `shouldReturn` 1

  it "submit-after-destroy with pooled also throws MultiplexerDead" $ do
    pool <- createSlotPool 16
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    threadDelay 10000
    result <- try $ submitCommandPooled pool mux (encodeCmd ["GET", "key"])
    case result of
      Left (e :: SomeException) -> show e `shouldContain` "MultiplexerDead"
      Right _ -> expectationFailure "Expected MultiplexerDead exception"

  it "destroy wakes a sent but unanswered submitter" $ do
    (client, awaitSend, _) <- createBlockingClient
    mux <- createMultiplexer client (receive client)
    resultVar <- newEmptyMVar

    _ <- forkIO $ do
      result <- try $ submitCommand mux (encodeCmd ["GET", "blocked"])
      putMVar resultVar result

    awaitSend
    destroyMultiplexer mux
    result <- timeout 1000000 (takeMVar resultVar)
    result `shouldSatisfy` isTimedMultiplexerDead

  it "a later destroy resumes cancelled teardown across active, pending, and queued slots" $
    runOnCapabilityZero $ do
      -- All acquisition and release workers are pinned to stripe zero. With
      -- createSlotPool 16 this starts with exactly four slots, so the eight
      -- held slots fully characterize the stripe after teardown.
      pool <- createSlotPool 16
      ( client
        , awaitFirstSend
        , awaitSecondSendGate
        , awaitReceive
        , releaseSecondSend
        , awaitCloseStart
        , releaseClose
        ) <-
        createTeardownClient
      mux <- createMultiplexer client (receive client)
      firstSlot <- submitCommandAsync pool mux (encodeCmd ["GET", "reader-owned"])
      firstResult <- waitForSlotInThread pool firstSlot
      awaitFirstSend
      awaitReceive

      secondSlot <- submitCommandAsync pool mux (encodeCmd ["GET", "pending"])
      secondResult <- waitForSlotInThread pool secondSlot
      -- This barrier is emitted inside the writer's uninterruptible send gate,
      -- immediately before its deliberately blocked operation.
      awaitSecondSendGate

      queuedSlots <- mapM
        (\idx -> submitCommandAsync pool mux
          (encodeCmd ["GET", LBS.toStrict $ Builder.toLazyByteString $ Builder.intDec idx]))
        [1 :: Int .. 6]
      let destroyedSlots = firstSlot : secondSlot : queuedSlots
      allDistinctResponseSlots destroyedSlots `shouldBe` True
      queuedResults <- mapM (waitForSlotInThread pool) queuedSlots
      ownerFinished <- newEmptyMVar
      owner <- forkFinally (destroyMultiplexer mux) (putMVar ownerFinished)
      -- This is a separate barrier: it proves the owner entered destroy's
      -- teardown sequence after the writer was already inside its send gate.
      awaitCloseStart

      killThread owner
      cancelledOwner <- timeout 1000000 (takeMVar ownerFinished)
      cancelledOwner `shouldSatisfy` isTimedThreadKilled

      releaseClose
      releaseSecondSend
      resumedDestroy <- timeout 1000000 (destroyMultiplexer mux)
      resumedDestroy `shouldBe` Just ()

      results <- timeout 1000000 $
        mapM takeMVar (firstResult : secondResult : queuedResults)
      results `shouldSatisfy` \case
        Just completed -> all isMultiplexerDead completed
        Nothing        -> False

      -- Reacquisition and its subsequent releases stay on stripe zero. The
      -- exact identity set proves teardown returned each of the eight failed
      -- slots once, rather than borrowing a slot from another stripe.
      (reuseClient, addReuseResponse) <- createMockClient
      reuseMux <- createMultiplexer reuseClient (receive reuseClient)
      reuseSlots <- replicateM 8 newEmptyMVar
      reuseResults <- replicateM 8 newEmptyMVar
      mapM_ (\(slotVar, resultVar) -> do
        _ <- forkOn 0 $ do
          slot <- submitCommandAsync pool reuseMux (encodeCmd ["PING"])
          putMVar slotVar slot
          result <- try (waitSlot pool slot) :: IO (Either SomeException RespData)
          putMVar resultVar result
        return ()
        ) (zip reuseSlots reuseResults)
      acquired <- mapM takeMVar reuseSlots
      sameResponseSlotSet destroyedSlots acquired `shouldBe` True
      addReuseResponse $ mconcat
        [ encodeResp (RespInteger response)
        | response <- [1 .. 8]
        ]
      reused <- mapM takeMVar reuseResults
      sort (map okResponseInteger reused) `shouldBe` map Just [1 .. 8]
      destroyMultiplexer reuseMux

  it "concurrent destroy calls are idempotent and wake the waiter once" $ do
    pool <- createSlotPool 16
    (client, awaitSend, _) <- createBlockingClient
    mux <- createMultiplexer client (receive client)
    resultVar <- newEmptyMVar

    _ <- forkIO $ do
      result <- try $ submitCommandPooled pool mux (encodeCmd ["GET", "blocked"])
      putMVar resultVar result

    awaitSend
    destroyDone <- replicateM 8 newEmptyMVar
    mapM_ (\done -> do
      _ <- forkIO $ destroyMultiplexer mux >> putMVar done ()
      return ()
      ) destroyDone

    destroysCompleted <- timeout 1000000 $ mapM_ takeMVar destroyDone
    destroysCompleted `shouldBe` Just ()
    result <- timeout 1000000 (takeMVar resultVar)
    result `shouldSatisfy` isTimedMultiplexerDead

    replicateM_ 3 (destroyMultiplexer mux)

    -- Reusing the same pool concurrently would hang if teardown had returned
    -- the same ResponseSlot more than once.
    (reuseClient, addRecv) <- createMockClient
    reuseMux <- createMultiplexer reuseClient (receive reuseClient)
    reuseResults <- replicateM 2 newEmptyMVar
    mapM_ (\reuseResultVar -> do
      _ <- forkIO $ do
        reuseResult <- try (submitCommandPooled pool reuseMux (encodeCmd ["PING"]))
          :: IO (Either SomeException RespData)
        putMVar reuseResultVar reuseResult
      return ()
      ) reuseResults
    threadDelay 10000
    addRecv $ encodeResp (RespSimpleString "OK") <> encodeResp (RespSimpleString "OK")
    reused <- timeout 1000000 $ mapM takeMVar reuseResults
    reused `shouldSatisfy` \case
      Just completed -> all isOkResponse completed
      Nothing        -> False
    destroyMultiplexer reuseMux

  it "returns the destroyed pooled slot exactly once for deterministic reuse" $
    runOnCapabilityZero $ do
      pool <- createSlotPool 1
      (client, awaitSend, _) <- createBlockingClient
      mux <- createMultiplexer client (receive client)
      destroyedSlot <- submitCommandAsync pool mux (encodeCmd ["GET", "blocked"])

      awaitSend
      destroyMultiplexer mux
      destroyedResult <- try (waitSlot pool destroyedSlot)
        :: IO (Either SomeException RespData)
      destroyedResult `shouldSatisfy` isMultiplexerDead

      (reuseClient, addRecv) <- createMockClient
      reuseMux <- createMultiplexer reuseClient (receive reuseClient)
      reusedSlot <- submitCommandAsync pool reuseMux (encodeCmd ["PING"])
      sameResponseSlot destroyedSlot reusedSlot `shouldBe` True

      premature <- timeout 50000 (waitSlot pool reusedSlot)
      premature `shouldBe` Nothing
      addRecv $ encodeResp (RespSimpleString "OK")
      completed <- timeout 1000000 (waitSlot pool reusedSlot)
      completed `shouldBe` Just (RespSimpleString "OK")
      destroyMultiplexer reuseMux

  it "worker failure racing destroy completes every waiter across 50 repetitions" $
    replicateM_ 50 $ do
      pool <- createSlotPool 16
      (client, awaitSend, reply) <- createBlockingClient
      mux <- createMultiplexer client (receive client)
      resultVars <- replicateM 4 newEmptyMVar

      mapM_ (\resultVar -> do
        _ <- forkIO $ do
          result <- try $ submitCommandPooled pool mux (encodeCmd ["GET", "race"])
          putMVar resultVar result
        return ()
        ) resultVars

      awaitSend
      _ <- forkIO $ reply "not-resp"
      destroyMultiplexer mux

      results <- timeout 1000000 $ mapM takeMVar resultVars
      results `shouldSatisfy` \case
        Just completed -> all isMultiplexerFailure completed
        Nothing        -> False

  it "handles multiple sequential commands correctly" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    -- Send multiple commands and verify ordering
    addRecv (encodeResp (RespSimpleString "OK"))
    r1 <- submitCommand mux (encodeCmd ["SET", "k1", "v1"])
    r1 `shouldBe` RespSimpleString "OK"

    addRecv (encodeResp (RespBulkString "v1"))
    r2 <- submitCommand mux (encodeCmd ["GET", "k1"])
    r2 `shouldBe` RespBulkString "v1"

    addRecv (encodeResp (RespInteger 1))
    r3 <- submitCommand mux (encodeCmd ["DEL", "k1"])
    r3 `shouldBe` RespInteger 1

    addRecv (encodeResp RespNullBulkString)
    r4 <- submitCommand mux (encodeCmd ["GET", "k1"])
    r4 `shouldBe` RespNullBulkString

    destroyMultiplexer mux

  it "handles RespArray responses" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    let arrResp = RespArray [RespBulkString "v1", RespBulkString "v2", RespNullBulkString]
    addRecv (encodeResp arrResp)
    resp <- submitCommand mux (encodeCmd ["MGET", "k1", "k2", "k3"])
    resp `shouldBe` arrResp
    destroyMultiplexer mux

  it "handles RespError responses without crashing" $ do
    (client, addRecv) <- createMockClient
    mux <- createMultiplexer client (receive client)
    addRecv (encodeResp (RespError "ERR wrong number of arguments"))
    resp <- submitCommand mux (encodeCmd ["GET"])
    resp `shouldBe` RespError "ERR wrong number of arguments"
    destroyMultiplexer mux

isMultiplexerAliveSpec :: Spec
isMultiplexerAliveSpec = describe "isMultiplexerAlive" $ do
  it "returns True for a live multiplexer" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    alive <- isMultiplexerAlive mux
    alive `shouldBe` True
    destroyMultiplexer mux

  it "returns False after destroy" $ do
    (client, _) <- createMockClient
    mux <- createMultiplexer client (receive client)
    destroyMultiplexer mux
    threadDelay 10000
    alive <- isMultiplexerAlive mux
    alive `shouldBe` False

waitForSlotInThread
  :: SlotPool
  -> ResponseSlot
  -> IO (MVar (Either SomeException RespData))
waitForSlotInThread pool slot = do
  resultVar <- newEmptyMVar
  _ <- forkOn 0 $ do
    result <- try $ waitSlot pool slot
    putMVar resultVar result
  return resultVar

runOnCapabilityZero :: IO () -> IO ()
runOnCapabilityZero action = do
  resultVar <- newEmptyMVar
  _ <- forkOn 0 $ do
    result <- try action
    putMVar resultVar result
  outcome <- timeout 3000000 (takeMVar resultVar)
  case outcome of
    Nothing         -> expectationFailure "pinned slot reuse test timed out"
    Just (Left err) -> throwIO (err :: SomeException)
    Just (Right ()) -> return ()

isTimedMultiplexerDead
  :: Maybe (Either SomeException RespData)
  -> Bool
isTimedMultiplexerDead (Just result) = isMultiplexerDead result
isTimedMultiplexerDead Nothing       = False

isTimedThreadKilled :: Maybe (Either SomeException ()) -> Bool
isTimedThreadKilled (Just (Left e)) =
  case fromException e of
    Just ThreadKilled -> True
    _                 -> False
isTimedThreadKilled _ = False

isMultiplexerDead :: Either SomeException RespData -> Bool
isMultiplexerDead (Left e) =
  case fromException e of
    Just (MultiplexerDead _) -> True
    _                        -> False
isMultiplexerDead (Right _) = False

isMultiplexerFailure :: Either SomeException RespData -> Bool
isMultiplexerFailure (Left e) =
  case fromException e of
    Just (MultiplexerDead _)         -> True
    Just (MultiplexerParseError _)   -> True
    Just MultiplexerConnectionClosed -> True
    Nothing                          -> False
isMultiplexerFailure (Right _) = False

allDistinctResponseSlots :: [ResponseSlot] -> Bool
allDistinctResponseSlots slots =
  and
    [ not (sameResponseSlot left right)
    | (index, left) <- zip [0 :: Int ..] slots
    , right <- drop (index + 1) slots
    ]

sameResponseSlotSet :: [ResponseSlot] -> [ResponseSlot] -> Bool
sameResponseSlotSet left right =
  length left == length right
    && allDistinctResponseSlots left
    && allDistinctResponseSlots right
    && all (\slot -> any (sameResponseSlot slot) right) left
    && all (\slot -> any (sameResponseSlot slot) left) right

isTimedMultiplexerParseFailure
  :: Maybe (Either SomeException RespData)
  -> Bool
isTimedMultiplexerParseFailure (Just (Left e)) =
  case fromException e of
    Just (MultiplexerParseError _) -> True
    _                              -> False
isTimedMultiplexerParseFailure _ = False

isOkResponse :: Either SomeException RespData -> Bool
isOkResponse (Right (RespSimpleString "OK")) = True
isOkResponse _                               = False

okResponseInteger :: Either SomeException RespData -> Maybe Integer
okResponseInteger (Right (RespInteger value)) = Just value
okResponseInteger _                           = Nothing
