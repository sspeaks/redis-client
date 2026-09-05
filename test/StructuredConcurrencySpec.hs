{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE KindSignatures #-}

module Main where

import           ClusterFiller            (withClusterFillConnection)
import           Control.Concurrent.Async (async, cancel, waitCatch)
import           Control.Concurrent.MVar  (MVar, newEmptyMVar, putMVar,
                                           takeMVar)
import           Control.Exception        (SomeException, bracket, finally,
                                           mask, throwIO, try)
import           Control.Monad.IO.Class   (liftIO)
import qualified Data.ByteString.Lazy     as LBS
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef, writeIORef)
import           Database.Redis.Client    (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster   (NodeAddress (..))
import           StructuredConcurrency    (runConcurrentlyFailFast)
import           Test.Hspec               (anyException, describe, hspec, it,
                                           shouldReturn, shouldSatisfy,
                                           shouldThrow)

main :: IO ()
main = hspec $ do
  describe "standalone fill workers" $ do
    it "propagates a failure before connecting after joining a started sibling" $
      assertFailFast $ \release _ ->
        takeMVar release >> throwIO (userError "connect failed")

    it "propagates a failure during an actual send after joining a started sibling" $ do
      sends <- newCounter
      assertFailFast $ \release _ -> do
        takeMVar release
        record sends
        throwIO (userError "send failed")
      readIORef sends `shouldReturn` 1

    it "propagates a failure while awaiting a response after joining a started sibling" $ do
      sends <- newCounter
      sent <- newEmptyMVar
      response <- newEmptyMVar
      siblingGate <- newEmptyMVar
      siblingStarted <- newEmptyMVar
      siblingCancelled <- newEmptyMVar
      parent <- async $ runConcurrentlyFailFast
        [ record sends >> putMVar sent () >> takeMVar response
            >> throwIO (userError "response wait failed")
        , putMVar siblingStarted () >> takeMVar siblingGate
            `finally` putMVar siblingCancelled ()
        ]
      takeMVar siblingStarted
      takeMVar sent
      putMVar response ()
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      readIORef sends `shouldReturn` 1
      takeMVar siblingCancelled

  describe "benchmark workers" $ do
    it "fails fast when an actual async submission send fails" $ do
      sends <- newCounter
      assertFailFast $ \release _ -> do
        takeMVar release
        record sends
        throwIO (userError "benchmark submit send failed")
      readIORef sends `shouldReturn` 1

    it "cancels a worker blocked awaiting a submitted response" $ do
      responseWaiterStarted <- newEmptyMVar
      failureGate <- newEmptyMVar
      responseGate <- newEmptyMVar
      responseWaiterReleased <- newEmptyMVar
      parent <- async $ runConcurrentlyFailFast
        [ putMVar responseWaiterStarted () >> takeMVar responseGate
            `finally` putMVar responseWaiterReleased ()
        , takeMVar failureGate >> throwIO (userError "benchmark send failed")
        ]
      takeMVar responseWaiterStarted
      putMVar failureGate ()
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      takeMVar responseWaiterReleased

  describe "cancellation ownership" $ do
    it "cancels and joins siblings while bracketing connection, pool, and client cleanup" $ do
      started <- newEmptyMVar
      siblingStarted <- newEmptyMVar
      waitForCancel <- newEmptyMVar
      closed <- newCounter
      parent <- async $ runConcurrentlyFailFast
        [ bracket (pure ()) (\() -> record closed) $ \() ->
            bracket (pure ()) (\() -> record closed) $ \() ->
              bracket (pure ()) (\() -> record closed) $ \() -> do
                putMVar started ()
                takeMVar waitForCancel
        , putMVar siblingStarted () >> takeMVar waitForCancel
        ]
      takeMVar started
      takeMVar siblingStarted
      cancel parent
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      readIORef closed `shouldReturn` 3

  describe "cluster fill connection ownership" $ do
    it "closes a direct connection exactly once after normal use" $ do
      tracker <- newTracker
      withClusterFillConnection (trackedConnector tracker) testAddress $ \conn ->
        send conn LBS.empty
      assertClosedExactlyOnce tracker

    it "closes a direct connection when its job fails" $ do
      tracker <- newTracker
      result <- try $ withClusterFillConnection (trackedConnector tracker) testAddress $ \conn -> do
        send conn LBS.empty
        throwIO $ userError "cluster fill send failed"
      result `shouldSatisfy` isFailure
      assertClosedExactlyOnce tracker

    it "cancels a worker blocked awaiting a send response and closes its connection" $ do
      tracker <- newTracker
      responseWaitStarted <- newEmptyMVar
      responseGate <- newEmptyMVar
      failureGate <- newEmptyMVar
      parent <- async $ runConcurrentlyFailFast
        [ withClusterFillConnection (trackedConnector tracker) testAddress $ \conn -> do
            send conn LBS.empty
            putMVar responseWaitStarted ()
            takeMVar responseGate
        , takeMVar failureGate >> throwIO (userError "sibling send failed")
        ]
      takeMVar responseWaitStarted
      putMVar failureGate ()
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      assertClosedExactlyOnce tracker

    it "closes a blocked child worker connection when its parent is cancelled" $ do
      tracker <- newTracker
      started <- newEmptyMVar
      waitGate <- newEmptyMVar
      parent <- async $ withClusterFillConnection (trackedConnector tracker) testAddress $ \conn -> do
        send conn LBS.empty
        putMVar started ()
        takeMVar waitGate
      takeMVar started
      cancel parent
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      assertClosedExactlyOnce tracker

    it "rejects use of a connection after its job scope closes" $ do
      tracker <- newTracker
      withClusterFillConnection (trackedConnector tracker) testAddress $ \conn ->
        send conn LBS.empty
      send (TrackingClient tracker) LBS.empty `shouldThrow` anyException

assertFailFast :: (MVar () -> MVar () -> IO ()) -> IO ()
assertFailFast failingWorker = do
  failureGate <- newEmptyMVar
  siblingGate <- newEmptyMVar
  siblingStarted <- newEmptyMVar
  siblingCancelled <- newEmptyMVar
  parent <- async $ runConcurrentlyFailFast
    [ failingWorker failureGate siblingStarted
    , blockUntilCancelled siblingStarted siblingGate
        `finally` putMVar siblingCancelled ()
    ]
  takeMVar siblingStarted
  putMVar failureGate ()
  result <- waitCatch parent
  result `shouldSatisfy` isFailure
  takeMVar siblingCancelled

-- | Publishing readiness while masked guarantees that cancellation is queued
-- until this worker enters the restored, cancellable blocking operation.
blockUntilCancelled :: MVar () -> MVar () -> IO ()
blockUntilCancelled ready gate = mask $ \restore -> do
  putMVar ready ()
  restore (takeMVar gate)

newCounter :: IO (IORef Int)
newCounter = newIORef 0

record :: IORef Int -> IO ()
record ref = atomicModifyIORef' ref (\count -> (count + 1, ()))

isFailure :: Either SomeException () -> Bool
isFailure (Left _)   = True
isFailure (Right ()) = False

data Tracker = Tracker
  { trackerOpen   :: IORef Bool
  , trackerClosed :: IORef Int
  }

data TrackingClient (status :: ConnectionStatus) = TrackingClient Tracker

instance Client TrackingClient where
  connect (TrackingClient tracker) = liftIO (assertOpen tracker) >> pure (TrackingClient tracker)
  close (TrackingClient tracker) = liftIO $ do
    isOpen <- readIORef (trackerOpen tracker)
    if isOpen
      then do
        writeIORef (trackerOpen tracker) False
        record (trackerClosed tracker)
      else throwIO $ userError "connection closed more than once"
  abort = close
  send (TrackingClient tracker) _ = liftIO $ assertOpen tracker
  receive (TrackingClient tracker) = liftIO (assertOpen tracker) >> pure mempty

newTracker :: IO Tracker
newTracker = Tracker <$> newIORef True <*> newCounter

trackedConnector :: Tracker -> NodeAddress -> IO (TrackingClient 'Connected)
trackedConnector tracker _ = do
  writeIORef (trackerOpen tracker) True
  pure $ TrackingClient tracker

assertClosedExactlyOnce :: Tracker -> IO ()
assertClosedExactlyOnce tracker = do
  readIORef (trackerClosed tracker) `shouldReturn` 1
  readIORef (trackerOpen tracker) `shouldReturn` False

assertOpen :: Tracker -> IO ()
assertOpen tracker = do
  isOpen <- readIORef (trackerOpen tracker)
  if isOpen
    then pure ()
    else throwIO $ userError "use after close"

testAddress :: NodeAddress
testAddress = NodeAddress "tracked.cluster.test" 6379
