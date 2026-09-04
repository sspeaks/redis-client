{-# LANGUAGE LambdaCase #-}

module Main (main) where

import           Control.Concurrent       (forkFinally, killThread, threadDelay)
import           Control.Concurrent.MVar  (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception        (SomeAsyncException, SomeException,
                                           displayException, fromException,
                                           throwIO, try)
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef)
import           LibraryE2E.NodeLifecycle
import           System.Exit              (ExitCode (..))
import           System.Timeout           (timeout)
import           Test.Hspec

main :: IO ()
main = hspec $ describe "LibraryE2E node lifecycle" $ do
  it "stops, runs the body, restarts, and waits for readiness" $ do
    events <- newIORef []
    let operations = successfulOperations events
    withStoppedNodeUsing operations target $
      record events "body"
    readIORef events `shouldReturn`
      ["stop", "body", "start", "ready"]

  it "starts every stopped node before checking cluster readiness" $ do
    events <- newIORef []
    let operations = NodeLifecycleOps
          { stopNodeOperation = \node ->
              record events $ "stop-" ++ show (nodeNumber node)
          , startNodeOperation = \node ->
              record events $ "start-" ++ show (nodeNumber node)
          , waitNodeReady = \node ->
              record events $ "ready-" ++ show (nodeNumber node)
          }
        secondTarget = target
          { nodeNumber = 4
          , nodeContainer = "redis-cluster-node4"
          , targetHost = "redis4.local"
          , targetPort = 6382
          }
    withStoppedNodesUsing operations [target, secondTarget] $ return ()
    readIORef events `shouldReturn`
      [ "stop-3"
      , "stop-4"
      , "start-3"
      , "start-4"
      , "ready-3"
      , "ready-4"
      ]

  it "does not run the body when stop fails and still attempts recovery" $ do
    events <- newIORef []
    bodyRan <- newIORef False
    let operations = (successfulOperations events)
          { stopNodeOperation = \_ -> do
              record events "stop"
              throwIO $ userError "stop failed"
          }
    result <- try $ withStoppedNodeUsing operations target $
      atomicModifyIORef' bodyRan $ const (True, ())
      :: IO (Either SomeException ())
    case result of
      Left err -> displayException err `shouldContain` "stop failed"
      Right () -> expectationFailure "body ran after failed stop"
    readIORef bodyRan `shouldReturn` False
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "preserves a body failure after successful recovery" $ do
    events <- newIORef []
    let operations = successfulOperations events
    result <- try $ withStoppedNodeUsing operations target $ do
      record events "body"
      throwIO $ userError "body failed"
      :: IO (Either SomeException ())
    case result of
      Left err -> displayException err `shouldContain` "body failed"
      Right () -> expectationFailure "body failure unexpectedly succeeded"
    readIORef events `shouldReturn`
      ["stop", "body", "start", "ready"]

  it "restores the node before an enclosing timeout returns" $ do
    events <- newIORef []
    let operations = successfulOperations events
    result <- timeout 50000 $ withStoppedNodeUsing operations target $
      threadDelay 1000000
    result `shouldBe` Nothing
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "restores the node and rethrows asynchronous cancellation" $ do
    events <- newIORef []
    bodyStarted <- newEmptyMVar
    bodyBlock <- newEmptyMVar
    finished <- newEmptyMVar
    let operations = successfulOperations events
    owner <- forkFinally
      (withStoppedNodeUsing operations target $ do
        putMVar bodyStarted ()
        takeMVar bodyBlock :: IO ())
      (putMVar finished)
    timeout 1000000 (takeMVar bodyStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 $ takeMVar finished
    outcome `shouldSatisfy` \case
      Just (Left err) ->
        case fromException err :: Maybe SomeAsyncException of
          Just _  -> True
          Nothing -> False
      _ -> False
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "preserves cancellation received during readiness cleanup" $ do
    events <- newIORef []
    readinessStarted <- newEmptyMVar
    readinessBlock <- newEmptyMVar
    finished <- newEmptyMVar
    let operations = (successfulOperations events)
          { waitNodeReady = \_ -> do
              record events "ready"
              putMVar readinessStarted ()
              takeMVar readinessBlock
          }
    owner <- forkFinally
      (withStoppedNodeUsing operations target $ return ())
      (putMVar finished)
    timeout 1000000 (takeMVar readinessStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 $ takeMVar finished
    outcome `shouldSatisfy` \case
      Just (Left err) ->
        case fromException err :: Maybe SomeAsyncException of
          Just _  -> True
          Nothing -> False
      _ -> False
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "preserves cleanup cancellation after a synchronous body failure" $ do
    events <- newIORef []
    readinessStarted <- newEmptyMVar
    readinessBlock <- newEmptyMVar
    finished <- newEmptyMVar
    let operations = (successfulOperations events)
          { waitNodeReady = \_ -> do
              record events "ready"
              putMVar readinessStarted ()
              takeMVar readinessBlock
          }
    owner <- forkFinally
      (withStoppedNodeUsing operations target $
        throwIO (userError "primary body failure") :: IO ())
      (putMVar finished)
    timeout 1000000 (takeMVar readinessStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 $ takeMVar finished
    outcome `shouldSatisfy` \case
      Just (Left err) ->
        case fromException err :: Maybe SomeAsyncException of
          Just _  -> True
          Nothing -> False
      _ -> False
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "attempts readiness and returns a restart cleanup failure" $ do
    events <- newIORef []
    let operations = (successfulOperations events)
          { startNodeOperation = \_ -> do
              record events "start"
              throwIO $ userError "restart failed"
          }
    result <- try $ withStoppedNodeUsing operations target $ return ()
      :: IO (Either NodeLifecycleException ())
    case result of
      Left err -> displayException err `shouldContain` "restart failed"
      Right () -> expectationFailure "restart failure unexpectedly succeeded"
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "returns a readiness cleanup failure after restart succeeds" $ do
    events <- newIORef []
    let operations = (successfulOperations events)
          { waitNodeReady = \_ -> do
              record events "ready"
              throwIO $ userError "readiness failed"
          }
    result <- try $ withStoppedNodeUsing operations target $ return ()
      :: IO (Either NodeLifecycleException ())
    case result of
      Left err -> displayException err `shouldContain` "readiness failed"
      Right () -> expectationFailure "readiness failure unexpectedly succeeded"
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "bounds a readiness probe that never returns" $ do
    blocked <- newEmptyMVar
    result <- timeout 2000000
      (try (waitForReadinessUsing 1
        (\_ -> takeMVar blocked)
        target) :: IO (Either NodeReadinessFailure ()))
    result `shouldSatisfy` \case
      Just (Left failure) ->
        readinessWaitSeconds failure == 1
      _ -> False

  it "preserves both synchronous body and cleanup failures" $ do
    events <- newIORef []
    let operations = (successfulOperations events)
          { startNodeOperation = \_ -> do
              record events "start"
              throwIO $ userError "cleanup failed"
          }
    result <- try $ withStoppedNodeUsing operations target $
      throwIO $ userError "primary failed"
      :: IO (Either NodeLifecycleException ())
    case result of
      Left err -> do
        displayException err `shouldContain` "primary failed"
        displayException err `shouldContain` "cleanup failed"
      Right () -> expectationFailure "combined failure unexpectedly succeeded"
    readIORef events `shouldReturn` ["stop", "start", "ready"]

  it "checks Docker exit status and redacts sensitive diagnostics" $ do
    let runner _ _ _ =
          return
            ( ExitFailure 17
            , "password=not-for-logs"
            , "credential token=also-secret"
            )
    result <- try $ runNodeCommandUsing runner StopNode target
      :: IO (Either NodeCommandFailure ())
    case result of
      Left err -> do
        displayException err `shouldContain` "redis-cluster-node3"
        displayException err `shouldContain` "ExitFailure 17"
        displayException err `shouldContain` "<redacted"
        displayException err `shouldNotContain` "not-for-logs"
        displayException err `shouldNotContain` "also-secret"
      Right () -> expectationFailure "failed Docker stop unexpectedly succeeded"

  it "includes safe Docker stdout and stderr in command failures" $ do
    let runner _ _ _ =
          return
            ( ExitFailure 19
            , "container was not running"
            , "daemon unavailable"
            )
    result <- try $ runNodeCommandUsing runner StartNode target
      :: IO (Either NodeCommandFailure ())
    case result of
      Left err -> do
        displayException err `shouldContain` "container was not running"
        displayException err `shouldContain` "daemon unavailable"
        displayException err `shouldContain` "redis3.local:6381"
      Right () -> expectationFailure "failed Docker start unexpectedly succeeded"

target :: NodeTarget
target = NodeTarget
  { nodeNumber = 3
  , nodeContainer = "redis-cluster-node3"
  , targetHost = "redis3.local"
  , targetPort = 6381
  }

successfulOperations :: IORef [String] -> NodeLifecycleOps
successfulOperations events = NodeLifecycleOps
  { stopNodeOperation = const $ record events "stop"
  , startNodeOperation = const $ record events "start"
  , waitNodeReady = const $ record events "ready"
  }

record :: IORef [String] -> String -> IO ()
record events event =
  atomicModifyIORef' events $ \current ->
    (current ++ [event], ())
