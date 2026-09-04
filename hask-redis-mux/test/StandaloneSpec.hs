{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

module Main (main) where

import           Control.Concurrent.MVar   (MVar, newEmptyMVar, takeMVar)
import           Control.Exception         (SomeException, try)
import           Control.Monad.IO.Class    (liftIO)
import           Data.ByteString           (ByteString)
import           Data.IORef                (IORef, atomicModifyIORef', newIORef,
                                            readIORef)
import           Database.Redis.Client     (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster    (NodeAddress (..))
import           Database.Redis.Command    (RedisCommands (..))
import           Database.Redis.Standalone
import           Test.Hspec

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef Int) -> !(MVar ByteString) -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close (MockConnected closeCount _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send _ _ = return ()
  receive (MockConnected _ replies) = liftIO $ takeMVar replies

main :: IO ()
main = hspec $ describe "Standalone client lifecycle" $ do
  it "owns its transport, closes once, and remains terminal" $ do
    connectionCount <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    replies <- newEmptyMVar
    let connector _ = do
          atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
          return $ MockConnected closeCount replies

    client <- createStandaloneClient connector (NodeAddress "127.0.0.1" 6379)
    closeStandaloneClient client
    closeStandaloneClient client

    result <- try $ runStandaloneClient client (ping :: StandaloneCommandClient ByteString)
      :: IO (Either SomeException ByteString)
    result `shouldSatisfy` either (const True) (const False)
    readIORef connectionCount `shouldReturn` 1
    readIORef closeCount `shouldReturn` 1
