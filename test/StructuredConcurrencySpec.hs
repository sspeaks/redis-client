{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE KindSignatures #-}

module Main where

import           ClusterFiller            (fillNodeWithDataWithTimeout,
                                           withClusterFillConnection)
import           Control.Concurrent.Async (Async, async, waitCatch)
import           Control.Concurrent.STM   (TMVar, atomically, newEmptyTMVarIO,
                                           putTMVar, readTMVar, retry)
import           Control.Exception        (SomeException, bracket,
                                           fromException, throwIO, try)
import           Control.Monad.IO.Class   (liftIO)
import qualified Data.ByteString.Lazy     as LBS
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef, writeIORef)
import           Data.List                (isInfixOf)
import qualified Data.Map.Strict          as Map
import qualified Data.Set                 as Set
import           Database.Redis.Client    (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster   (NodeAddress (..))
import           ProcessLifecycle         (ChildProcessFailure (..),
                                           waitForChildProcesses)
import           StructuredConcurrency    (ConcurrentFailure (..),
                                           runConcurrentlyFailFast)
import           System.Exit              (ExitCode (ExitFailure))
import           System.Process           (createProcess, proc)
import           System.Timeout           (timeout)
import           Test.Hspec

phaseTimeout :: Int
phaseTimeout = 1000000

main :: IO ()
main = hspec $ do
  describe "structured worker ownership" $ do
    it "propagates a body failure after cancelling and joining a blocked sibling" $ do
      ready <- newPhase
      release <- newPhase
      parent <- async $ runConcurrentlyFailFast
        [ awaitPhase release >> throwIO (userError "connect failure")
        , blockingWorker ready
        ]
      awaitPhase ready
      signalPhase release
      result <- awaitResult parent
      result `shouldSatisfy` isFailure

    it "preserves a body failure and reports a sibling close failure" $ do
      ready <- newPhase
      release <- newPhase
      parent <- async $ runConcurrentlyFailFast
        [ awaitPhase release >> throwIO (userError "send failure")
        , bracket (pure ()) (\() -> throwIO (userError "sibling close failure")) $ \() ->
            blockingWorker ready
        ]
      awaitPhase ready
      signalPhase release
      result <- awaitResult parent
      assertConcurrentFailure "send failure" 1 result

    it "reports every simultaneous sibling cleanup failure" $ do
      readyOne <- newPhase
      readyTwo <- newPhase
      release <- newPhase
      parent <- async $ runConcurrentlyFailFast
        [ awaitPhase release >> throwIO (userError "primary body failure")
        , failingCleanupWorker readyOne "close one"
        , failingCleanupWorker readyTwo "close two"
        ]
      awaitPhase readyOne
      awaitPhase readyTwo
      signalPhase release
      result <- awaitResult parent
      assertConcurrentFailure "primary body failure" 2 result

  describe "cluster fill worker connection ownership" $ do
    it "closes each acquired direct transport exactly once after success" $ do
      tracker <- newTracker False False
      withClusterFillConnection (trackedConnector tracker) testAddress $ \conn ->
        send conn LBS.empty
      assertAllConnectionsClosedOnce tracker 1

    it "does not close when direct transport acquisition fails" $ do
      tracker <- newTracker False False
      result <- try (withClusterFillConnection (failingConnector tracker) testAddress (\_ -> pure ())) :: IO (Either SomeException ())
      result `shouldSatisfy` isFailure
      assertAllConnectionsClosedOnce tracker 0

    it "closes a worker transport after a send/body failure" $ do
      tracker <- newTracker False False
      result <- try (withClusterFillConnection (trackedConnector tracker) testAddress $ \conn -> do
        send conn LBS.empty
        throwIO (userError "send failure")) :: IO (Either SomeException ())
      result `shouldSatisfy` isFailure
      assertAllConnectionsClosedOnce tracker 1

    it "surfaces close failure over a same-resource body failure after closing it" $ do
      tracker <- newTracker True False
      result <- try (withClusterFillConnection (trackedConnector tracker) testAddress $ \_ ->
        throwIO (userError "body failure")) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "close failure"
      assertAllConnectionsClosedOnce tracker 1

    it "times out through the production fill worker and closes the transport" $ do
      tracker <- newTracker False True
      result <- try (withClusterFillConnection (trackedConnector tracker) testAddress $ \conn ->
        fillNodeWithDataWithTimeout 1 conn [0] 1 1 0 8 8 1) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "timed out"
      assertAllConnectionsClosedOnce tracker 1

    it "rejects a production-scoped transport after it has closed" $ do
      tracker <- newTracker False False
      escaped <- newIORef Nothing
      withClusterFillConnection (trackedConnector tracker) testAddress $ \conn ->
        writeIORef escaped (Just conn)
      Just conn <- readIORef escaped
      send conn LBS.empty `shouldThrow` anyException
      assertAllConnectionsClosedOnce tracker 1

  describe "multiprocess fill ownership" $
    it "waits for every real child then propagates its non-zero exit status" $ do
      (_, _, _, successfulChild) <- createProcess (proc "/bin/sh" ["-c", "exit 0"])
      (_, _, _, failingChild) <- createProcess (proc "/bin/sh" ["-c", "exit 7"])
      result <- try (waitForChildProcesses [successfulChild, failingChild]) :: IO (Either SomeException ())
      case result of
        Left exception ->
          case fromException exception :: Maybe ChildProcessFailure of
            Nothing -> expectationFailure $ "unexpected result: " ++ show exception
            Just (ChildProcessFailure index exitCode) -> do
              index `shouldBe` 1
              exitCode `shouldBe` ExitFailure 7
        Right () -> expectationFailure "expected a non-zero child exit to fail the parent"

newPhase :: IO (TMVar ())
newPhase = newEmptyTMVarIO

signalPhase :: TMVar () -> IO ()
signalPhase phase = atomically $ putTMVar phase ()

awaitPhase :: TMVar () -> IO ()
awaitPhase phase = do
  result <- timeout phaseTimeout (atomically $ readTMVar phase)
  result `shouldBe` Just ()

awaitResult :: Async () -> IO (Either SomeException ())
awaitResult worker = do
  result <- timeout phaseTimeout (waitCatch worker)
  case result of
    Nothing -> expectationFailure "worker did not finish within the diagnostic phase bound" >> error "unreachable"
    Just outcome -> pure outcome

failingCleanupWorker :: TMVar () -> String -> IO ()
failingCleanupWorker ready message =
  bracket (pure ()) (\() -> throwIO (userError message)) $ \() -> do
    blockingWorker ready

blockingWorker :: TMVar () -> IO ()
blockingWorker ready = do
  never <- newPhase
  signalPhase ready
  awaitPhase never

assertConcurrentFailure :: String -> Int -> Either SomeException () -> Expectation
assertConcurrentFailure primary expectedCleanup result =
  case result of
    Left exception ->
      case fromException exception :: Maybe ConcurrentFailure of
        Nothing -> expectationFailure $ "expected ConcurrentFailure, got: " ++ show exception
        Just failure -> do
          show (concurrentPrimaryFailure failure) `shouldSatisfy` isInfixOf primary
          length (concurrentSiblingCleanupFailures failure) `shouldBe` expectedCleanup
    Right () -> expectationFailure "expected worker failure"

isFailure :: Either SomeException () -> Bool
isFailure (Left _)  = True
isFailure (Right _) = False

data Tracker = Tracker
  { trackerNextId        :: IORef Int
  , trackerLive          :: IORef (Set.Set Int)
  , trackerCloseCounts   :: IORef (Map.Map Int Int)
  , trackerCloseFails    :: Bool
  , trackerBlocksReceive :: Bool
  }

data TrackingClient (status :: ConnectionStatus) = TrackingClient Tracker Int

instance Client TrackingClient where
  connect (TrackingClient tracker connectionId) =
    liftIO (assertOpen tracker connectionId) >> pure (TrackingClient tracker connectionId)
  close (TrackingClient tracker connectionId) = liftIO $ do
    assertOpen tracker connectionId
    atomicModifyIORef' (trackerLive tracker) (\live -> (Set.delete connectionId live, ()))
    atomicModifyIORef' (trackerCloseCounts tracker)
      (\counts -> (Map.insertWith (+) connectionId 1 counts, ()))
    if trackerCloseFails tracker
      then throwIO (userError "close failure")
      else pure ()
  abort = close
  send (TrackingClient tracker connectionId) _ = liftIO $ assertOpen tracker connectionId
  receive (TrackingClient tracker connectionId) = liftIO $ do
    assertOpen tracker connectionId
    if trackerBlocksReceive tracker then atomically retry else pure mempty

newTracker :: Bool -> Bool -> IO Tracker
newTracker closeFails blocksReceive =
  Tracker <$> newIORef 0 <*> newIORef Set.empty <*> newIORef Map.empty
    <*> pure closeFails <*> pure blocksReceive

trackedConnector :: Tracker -> NodeAddress -> IO (TrackingClient 'Connected)
trackedConnector tracker _ = do
  connectionId <- atomicModifyIORef' (trackerNextId tracker) (\n -> (n + 1, n))
  atomicModifyIORef' (trackerLive tracker) (\live -> (Set.insert connectionId live, ()))
  pure $ TrackingClient tracker connectionId

failingConnector :: Tracker -> NodeAddress -> IO (TrackingClient 'Connected)
failingConnector _ _ = throwIO $ userError "acquire failure"

assertAllConnectionsClosedOnce :: Tracker -> Int -> IO ()
assertAllConnectionsClosedOnce tracker expected = do
  live <- readIORef (trackerLive tracker)
  counts <- readIORef (trackerCloseCounts tracker)
  Set.null live `shouldBe` True
  Map.size counts `shouldBe` expected
  mapM_ (`shouldBe` 1) (Map.elems counts)

assertOpen :: Tracker -> Int -> IO ()
assertOpen tracker connectionId = do
  live <- readIORef (trackerLive tracker)
  if Set.member connectionId live
    then pure ()
    else throwIO $ userError "use after close"

testAddress :: NodeAddress
testAddress = NodeAddress "tracked.cluster.test" 6379
