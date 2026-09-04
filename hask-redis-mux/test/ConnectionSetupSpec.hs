module Main (main) where

import           Control.Concurrent.MVar               (MVar, newEmptyMVar,
                                                        takeMVar)
import           Control.Exception                     (throwIO)
import           Data.IORef                            (atomicModifyIORef',
                                                        newIORef, readIORef)
import           Database.Redis.Client.ConnectionSetup (withSetupResource)
import           GHC.Clock                             (getMonotonicTimeNSec)
import           System.Timeout                        (timeout)
import           Test.Hspec

main :: IO ()
main = hspec $ describe "Connection setup cleanup" $ do
  mapM_ stalledSetupCase ["plaintext TCP connect", "TLS handshake"]
  mapM_ failedSetupCase ["plaintext TCP connect", "TLS context setup", "TLS handshake"]

stalledSetupCase :: String -> Spec
stalledSetupCase phase =
  it ("closes once when " <> phase <> " exceeds its deadline") $ do
    allocations <- newIORef (0 :: Int)
    closes <- newIORef (0 :: Int)
    stalled <- newEmptyMVar :: IO (MVar ())
    let acquire =
          atomicModifyIORef' allocations $ \count -> (count + 1, count + 1)
        release _ =
          atomicModifyIORef' closes $ \count -> (count + 1, ())

    started <- getMonotonicTimeNSec
    result <- timeout 50000 $
      withSetupResource acquire release $ \_ -> takeMVar stalled
    finished <- getMonotonicTimeNSec
    let elapsedSeconds =
          fromIntegral (finished - started) / 1000000000 :: Double

    result `shouldBe` Nothing
    elapsedSeconds `shouldSatisfy` \elapsed ->
      elapsed >= 0.02 && elapsed < 0.5
    readIORef allocations `shouldReturn` 1
    readIORef closes `shouldReturn` 1

failedSetupCase :: String -> Spec
failedSetupCase phase =
  it ("closes once when " <> phase <> " fails") $ do
    closes <- newIORef (0 :: Int)
    let release _ =
          atomicModifyIORef' closes $ \count -> (count + 1, ())
        failure = throwIO $ userError $ "injected " <> phase <> " failure"

    withSetupResource (return ()) release (const failure)
      `shouldThrow` anyIOException
    readIORef closes `shouldReturn` 1
