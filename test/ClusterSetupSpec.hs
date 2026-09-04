{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import           AppConfig                (RunState (..), defaultRunState)
import           ClusterSetup             (authenticateClient,
                                           createAuthenticatedConnectorWithTimeout)
import           Control.Concurrent       (forkFinally, killThread)
import           Control.Concurrent.MVar  (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception        (SomeException, finally,
                                           fromException, throwIO, try)
import           Control.Monad.IO.Class   (liftIO)
import           Data.ByteString          (ByteString)
import           Data.IORef               (IORef, atomicModifyIORef', newIORef,
                                           readIORef)
import           Data.List                (isInfixOf)
import           Database.Redis.Client    (Client (..), ConnectionPhase (..),
                                           ConnectionStatus (..))
import           Database.Redis.Cluster   (NodeAddress (..))
import           Database.Redis.Connector (ConnectionSetupException (..))
import           GHC.Clock                (getMonotonicTimeNSec)
import           System.Timeout           (timeout)
import           Test.Hspec

data AuthClient (status :: ConnectionStatus) where
  AuthConnected
    :: !(IORef Int)
    -> !(IORef Int)
    -> !(IO ByteString)
    -> AuthClient 'Connected

instance Show (AuthClient status) where
  show _ = "AuthClient"

instance Client AuthClient where
  connect = error "AuthClient: connect not supported"
  close (AuthConnected gracefulCloseCount _ _) =
    liftIO $ increment gracefulCloseCount
  abort (AuthConnected _ abortCount _) =
    liftIO $ increment abortCount
  send _ _ = return ()
  receive (AuthConnected _ _ receiveAction) = liftIO receiveAction

main :: IO ()
main = hspec $ describe "authenticated production connector" $ do
  it "uses abortive cleanup when direct authentication is cancelled" $ do
    gracefulCloses <- newIORef (0 :: Int)
    aborts <- newIORef (0 :: Int)
    receiveStarted <- newEmptyMVar
    stalled <- newEmptyMVar
    finished <- newEmptyMVar
    let client = AuthConnected gracefulCloses aborts $
          putMVar receiveStarted () >> takeMVar stalled

    owner <- forkFinally
      (authenticateClient credentialState client)
      (putMVar finished)
    timeout 1000000 (takeMVar receiveStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 (takeMVar finished)
    outcome `shouldSatisfy` \case
      Just (Left _) -> True
      _             -> False
    readIORef gracefulCloses `shouldReturn` 0
    readIORef aborts `shouldReturn` 1

  it "times out the actual authenticated connector with typed redacted error" $ do
    gracefulCloses <- newIORef (0 :: Int)
    aborts <- newIORef (0 :: Int)
    receiveStarted <- newEmptyMVar
    stalled <- newEmptyMVar
    workerFinished <- newEmptyMVar
    let receiveAction =
          (putMVar receiveStarted () >> takeMVar stalled)
            `finally` putMVar workerFinished ()
        client = AuthConnected gracefulCloses aborts receiveAction
        connector = createAuthenticatedConnectorWithTimeout
          1 credentialState (\_ _ -> return client)

    startedAt <- getMonotonicTimeNSec
    result <- try $ connector testNode
      :: IO (Either SomeException (AuthClient 'Connected))
    finishedAt <- getMonotonicTimeNSec
    let elapsed =
          fromIntegral (finishedAt - startedAt) / 1000000000 :: Double

    result `shouldSatisfy` \case
      Left err ->
        case fromException err of
          Just timeoutError ->
            connectionTimeoutPhase timeoutError == Authentication
              && connectionTimeoutEndpoint timeoutError == testNode
              && not (syntheticCredential `isInfixOf` show timeoutError)
          Nothing -> False
      Right _ -> False
    elapsed `shouldSatisfy` \seconds ->
      seconds >= 0.75 && seconds < 2.5
    timeout 1000000 (takeMVar workerFinished) `shouldReturn` Just ()
    readIORef gracefulCloses `shouldReturn` 0
    readIORef aborts `shouldReturn` 1

  it "abortively closes exactly once on synchronous AUTH failure" $ do
    gracefulCloses <- newIORef (0 :: Int)
    aborts <- newIORef (0 :: Int)
    let client = AuthConnected gracefulCloses aborts $
          throwIO $ userError "synthetic AUTH rejection"
        connector = createAuthenticatedConnectorWithTimeout
          5 credentialState (\_ _ -> return client)

    result <- try $ connector testNode
      :: IO (Either SomeException (AuthClient 'Connected))
    result `shouldSatisfy` \case
      Left err -> not (syntheticCredential `isInfixOf` show err)
      Right _  -> False
    readIORef gracefulCloses `shouldReturn` 0
    readIORef aborts `shouldReturn` 1

credentialState :: RunState
credentialState = defaultRunState
  { username = "default"
  , password = syntheticCredential
  }

syntheticCredential :: String
syntheticCredential = "synthetic-secret-for-redaction"

testNode :: NodeAddress
testNode = NodeAddress "redis.test" 6380

increment :: IORef Int -> IO ()
increment ref =
  atomicModifyIORef' ref $ \count -> (count + 1, ())
