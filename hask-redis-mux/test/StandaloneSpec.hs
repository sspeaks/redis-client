{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent        (threadDelay)
import           Control.Concurrent.MVar   (MVar, newEmptyMVar, putMVar,
                                            takeMVar)
import           Control.Exception         (SomeException, try)
import           Control.Monad.IO.Class    (liftIO)
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Builder   as Builder
import qualified Data.ByteString.Lazy      as LBS
import           Data.IORef                (IORef, atomicModifyIORef', newIORef,
                                            readIORef)
import           Database.Redis.Client     (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster    (NodeAddress (..))
import           Database.Redis.Command    (RedisCommands (..),
                                            encodeCommandBuilder)
import           Database.Redis.Resp       (RespData (..))
import           Database.Redis.Standalone
import           Test.Hspec

data MockClient (a :: ConnectionStatus) where
  MockConnected
    :: !(IORef Int)
    -> !(MVar ByteString)
    -> !(IORef ByteString)
    -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close (MockConnected closeCount _ _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send (MockConnected _ _ sent) lbs =
    liftIO $ atomicModifyIORef' sent $ \old ->
      (old <> LBS.toStrict lbs, ())
  receive (MockConnected _ replies sent) = liftIO $ do
    waitForSend sent
    takeMVar replies

main :: IO ()
main = hspec $ do
  describe "Standalone client lifecycle" $ do
    it "owns its transport, closes once, and remains terminal" $ do
      connectionCount <- newIORef (0 :: Int)
      closeCount <- newIORef (0 :: Int)
      replies <- newEmptyMVar
      sent <- newIORef BS.empty
      let connector _ = do
            atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
            return $ MockConnected closeCount replies sent

      client <- createStandaloneClient connector (NodeAddress "127.0.0.1" 6379)
      closeStandaloneClient client
      closeStandaloneClient client

      result <- try $ runStandaloneClient client (ping :: StandaloneCommandClient ByteString)
        :: IO (Either SomeException ByteString)
      result `shouldSatisfy` either (const True) (const False)
      readIORef connectionCount `shouldReturn` 1
      readIORef closeCount `shouldReturn` 1

  describe "Standalone authentication protocol" $ do
    it "uses one-argument AUTH for the default user" $ do
      (client, replies, sent) <- createCommandClient
      putMVar replies "+OK\r\n"
      runStandaloneClient client
        (auth "default" "password-secret" :: StandaloneCommandClient RespData)
        `shouldReturn` RespSimpleString "OK"
      readIORef sent `shouldReturn`
        commandBytes ["AUTH", "password-secret"]
      closeStandaloneClient client

    it "uses HELLO 2 AUTH for a named ACL user" $ do
      (client, replies, sent) <- createCommandClient
      putMVar replies "*2\r\n$5\r\nproto\r\n:2\r\n"
      runStandaloneClient client
        (auth "acl-user" "acl-secret" :: StandaloneCommandClient RespData)
        `shouldReturn` RespArray [RespBulkString "proto", RespInteger 2]
      readIORef sent `shouldReturn`
        commandBytes ["HELLO", "2", "AUTH", "acl-user", "acl-secret"]
      closeStandaloneClient client

createCommandClient
  :: IO (StandaloneClient, MVar ByteString, IORef ByteString)
createCommandClient = do
  closeCount <- newIORef 0
  replies <- newEmptyMVar
  sent <- newIORef BS.empty
  client <- createStandaloneClient
    (const $ return $ MockConnected closeCount replies sent)
    (NodeAddress "127.0.0.1" 6379)
  return (client, replies, sent)

commandBytes :: [ByteString] -> ByteString
commandBytes =
  LBS.toStrict . Builder.toLazyByteString . encodeCommandBuilder

waitForSend :: IORef ByteString -> IO ()
waitForSend sent = do
  bytes <- readIORef sent
  if BS.null bytes
    then threadDelay 1000 >> waitForSend sent
    else return ()
