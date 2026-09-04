{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

module Main (main) where

import           AppConfig               (RunState (..), defaultRunState)
import           ClusterSetup            (authenticateClient)
import           Control.Concurrent      (forkFinally, killThread)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import           Control.Monad.IO.Class  (liftIO)
import           Data.ByteString         (ByteString)
import           Data.IORef              (IORef, atomicModifyIORef', newIORef,
                                          readIORef)
import           Database.Redis.Client   (Client (..), ConnectionStatus (..))
import           System.Timeout          (timeout)
import           Test.Hspec

data AuthClient (a :: ConnectionStatus) where
  AuthConnected
    :: !(IORef Int)
    -> !(MVar ())
    -> !(MVar ())
    -> AuthClient 'Connected

instance Client AuthClient where
  connect = error "AuthClient: connect not supported"
  close (AuthConnected closeCount _ _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send _ _ = return ()
  receive (AuthConnected _ receiveStarted stalled) = liftIO $ do
    putMVar receiveStarted ()
    takeMVar stalled
    return (mempty :: ByteString)

main :: IO ()
main = hspec $ describe "authenticated connector cleanup" $ do
  it "closes a connected transport when authentication is cancelled" $ do
    closeCount <- newIORef (0 :: Int)
    receiveStarted <- newEmptyMVar
    stalled <- newEmptyMVar
    finished <- newEmptyMVar
    let state = defaultRunState
          { username = "default"
          , password = "synthetic-credential"
          }
        client = AuthConnected closeCount receiveStarted stalled

    owner <- forkFinally (authenticateClient state client) (putMVar finished)
    timeout 1000000 (takeMVar receiveStarted) `shouldReturn` Just ()
    killThread owner
    outcome <- timeout 1000000 (takeMVar finished)
    case outcome of
      Just (Left _) -> return ()
      _             -> expectationFailure "authentication cancellation was not rethrown"
    readIORef closeCount `shouldReturn` 1
