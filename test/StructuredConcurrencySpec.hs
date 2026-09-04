module Main where

import           Control.Concurrent       (newEmptyMVar, putMVar, takeMVar,
                                           threadDelay)
import           Control.Concurrent.Async (async, cancel, waitCatch)
import           Control.Exception        (SomeException, finally, throwIO, try)
import           Control.Monad            (forever)
import           Data.IORef               (newIORef, readIORef, writeIORef)
import           Data.Maybe               (isJust)
import           StructuredConcurrency    (runConcurrentlyFailFast)
import           System.Timeout           (timeout)
import           Test.Hspec               (describe, hspec, it, shouldBe,
                                           shouldSatisfy)

main :: IO ()
main = hspec $ do
  describe "runConcurrentlyFailFast" $ do
    it "propagates pre-connect, send, and response-wait failures after cancelling siblings" $
      mapM_ assertFailure ["pre-connect", "send", "response-wait"]

    it "cancels children and waits for their cleanup when its parent is cancelled" $ do
      started <- newEmptyMVar
      siblingStarted <- newEmptyMVar
      released <- newIORef False
      parent <- async $ runConcurrentlyFailFast
        [ putMVar started () >> forever (threadDelay 1000000)
        , putMVar siblingStarted () >> forever (threadDelay 1000000) `finally` writeIORef released True
        ]
      takeMVar started
      takeMVar siblingStarted
      cancel parent
      completed <- timeout 1000000 (waitCatch parent)
      completed `shouldSatisfy` isJust
      wasReleased <- readIORef released
      wasReleased `shouldBe` True

assertFailure :: String -> IO ()
assertFailure phase = do
  released <- newIORef False
  result <- timeout 1000000 $ try $ runConcurrentlyFailFast
    [ throwIO (userError (phase ++ " failure"))
    , forever (threadDelay 1000000) `finally` writeIORef released True
    ] :: IO (Maybe (Either SomeException ()))
  result `shouldSatisfy` isFailure
  wasReleased <- readIORef released
  wasReleased `shouldBe` True

isFailure :: Maybe (Either SomeException ()) -> Bool
isFailure (Just (Left _)) = True
isFailure _               = False
