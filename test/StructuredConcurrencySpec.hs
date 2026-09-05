module Main where

import           Control.Concurrent.Async (async, cancel, waitCatch)
import           Control.Concurrent.MVar  (MVar, newEmptyMVar, putMVar,
                                           takeMVar)
import           Control.Exception        (SomeException, bracket, finally,
                                           throwIO)
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef)
import           StructuredConcurrency    (runConcurrentlyFailFast)
import           Test.Hspec               (describe, hspec, it, shouldReturn,
                                           shouldSatisfy)

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
      siblingStarted <- newEmptyMVar
      siblingReleased <- newEmptyMVar
      parent <- async $ runConcurrentlyFailFast
        [ record sends >> putMVar sent () >> takeMVar response
            >> throwIO (userError "response wait failed")
        , putMVar siblingStarted () >> takeMVar siblingReleased
            `finally` putMVar siblingReleased ()
        ]
      takeMVar siblingStarted
      takeMVar sent
      putMVar response ()
      result <- waitCatch parent
      result `shouldSatisfy` isFailure
      readIORef sends `shouldReturn` 1
      takeMVar siblingReleased

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

assertFailFast :: (MVar () -> MVar () -> IO ()) -> IO ()
assertFailFast failingWorker = do
  releaseFailure <- newEmptyMVar
  siblingStarted <- newEmptyMVar
  siblingReleased <- newEmptyMVar
  parent <- async $ runConcurrentlyFailFast
    [ failingWorker releaseFailure siblingStarted
    , putMVar siblingStarted () >> takeMVar siblingReleased
        `finally` putMVar siblingReleased ()
    ]
  takeMVar siblingStarted
  putMVar releaseFailure ()
  result <- waitCatch parent
  result `shouldSatisfy` isFailure
  takeMVar siblingReleased

newCounter :: IO (IORef Int)
newCounter = newIORef 0

record :: IORef Int -> IO ()
record ref = atomicModifyIORef' ref (\count -> (count + 1, ()))

isFailure :: Either SomeException () -> Bool
isFailure (Left _)   = True
isFailure (Right ()) = False
