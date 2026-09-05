{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent        (forkIO)
import           Control.Concurrent.MVar   (MVar, newEmptyMVar, putMVar,
                                            takeMVar, tryPutMVar, tryTakeMVar)
import           Control.Exception         (SomeException, try)
import           Control.Monad             (void)
import           Control.Monad.IO.Class    (liftIO)
import qualified Control.Monad.State       as State
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Builder   as Builder
import qualified Data.ByteString.Lazy      as LBS
import           Data.IORef                (IORef, atomicModifyIORef', newIORef,
                                            readIORef)
import           Database.Redis.Client     (Client (..), ConnectionStatus (..))
import           Database.Redis.Cluster    (NodeAddress (..))
import           Database.Redis.Command    (ClientReplyModeUnsupported (..),
                                            ClientReplyValues (..),
                                            ClientState (..),
                                            RedisCommandClient (..),
                                            RedisCommands (..),
                                            encodeCommandBuilder)
import           Database.Redis.Resp       (RespData (..))
import           Database.Redis.Standalone
import           System.Timeout            (timeout)
import           Test.Hspec

data MockClient (a :: ConnectionStatus) where
  MockConnected
    :: !(IORef Int)
    -> !(MVar ByteString)
    -> !(IORef ByteString)
    -> !(MVar ByteString)
    -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close (MockConnected closeCount _ _ _) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send (MockConnected _ _ sent sentEvent) lbs = liftIO $ do
    let bytes = LBS.toStrict lbs
    atomicModifyIORef' sent $ \old -> (old <> bytes, ())
    void $ tryPutMVar sentEvent bytes
  receive (MockConnected _ replies _ _) = liftIO $ takeMVar replies

main :: IO ()
main = hspec $ do
  describe "Standalone client lifecycle" $ do
    it "owns its transport, closes once, and remains terminal" $ do
      connectionCount <- newIORef (0 :: Int)
      closeCount <- newIORef (0 :: Int)
      replies <- newEmptyMVar
      sent <- newIORef BS.empty
      sentEvent <- newEmptyMVar
      let connector _ = do
            atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
            return $ MockConnected closeCount replies sent sentEvent

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
      (client, replies, sent, _) <- createCommandClient
      putMVar replies "+OK\r\n"
      runStandaloneClient client
        (auth "default" "password-secret" :: StandaloneCommandClient RespData)
        `shouldReturn` RespSimpleString "OK"
      readIORef sent `shouldReturn`
        commandBytes ["AUTH", "password-secret"]
      closeStandaloneClient client

    it "uses HELLO 2 AUTH for a named ACL user" $ do
      (client, replies, sent, _) <- createCommandClient
      putMVar replies "*2\r\n$5\r\nproto\r\n:2\r\n"
      runStandaloneClient client
        (auth "acl-user" "acl-secret" :: StandaloneCommandClient RespData)
        `shouldReturn` RespArray [RespBulkString "proto", RespInteger 2]
      readIORef sent `shouldReturn`
        commandBytes ["HELLO", "2", "AUTH", "acl-user", "acl-secret"]
      closeStandaloneClient client

  describe "Standalone CLIENT REPLY protocol" $ do
    it "sends SKIP without claiming the following response slot" $ do
      (client, replies, sent, sentEvent) <- createCommandClient
      skipped <- newEmptyMVar
      _ <- forkResult skipped $
        runStandaloneClient client
          (clientReply SKIP :: StandaloneCommandClient (Maybe RespData))

      awaitSent sentEvent `shouldReturn` Just (commandBytes ["CLIENT", "REPLY", "SKIP"])
      takeMVar skipped >>= \result -> case result of
        Right Nothing -> return ()
        _             -> expectationFailure "CLIENT REPLY SKIP did not complete successfully"

      pinged <- newEmptyMVar
      _ <- forkResult pinged $
        runStandaloneClient client (ping :: StandaloneCommandClient RespData)
      awaitSent sentEvent `shouldReturn` Just (commandBytes ["PING"])
      putMVar replies "+PONG\r\n"
      takeMVar pinged >>= \pingResult -> case pingResult of
        Right (RespSimpleString "PONG") -> return ()
        _                               -> expectationFailure "PING did not receive its own response"
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "SKIP"] <> commandBytes ["PING"]
      closeStandaloneClient client

    it "rejects OFF before sending, leaving arbitrary later commands reply-safe" $ do
      (client, replies, sent, sentEvent) <- createCommandClient
      result <- try $ runStandaloneClient client
        (clientReply OFF :: StandaloneCommandClient (Maybe RespData))
        :: IO (Either ClientReplyModeUnsupported (Maybe RespData))
      result `shouldBe` Left (ClientReplyModeUnsupported OFF)
      tryTakeMVar sentEvent `shouldReturn` Nothing
      readIORef sent `shouldReturn` BS.empty

      pinged <- newEmptyMVar
      _ <- forkResult pinged $
        runStandaloneClient client (ping :: StandaloneCommandClient RespData)
      awaitSent sentEvent `shouldReturn` Just (commandBytes ["PING"])
      putMVar replies "+PONG\r\n"
      takeMVar pinged >>= \pingResult -> case pingResult of
        Right (RespSimpleString "PONG") -> return ()
        _                               -> expectationFailure "PING did not remain reply-safe after OFF rejection"
      closeStandaloneClient client

    it "sends ON and consumes only its restored reply" $ do
      (client, replies, _, sentEvent) <- createCommandClient
      restored <- newEmptyMVar
      _ <- forkResult restored $
        runStandaloneClient client
          (clientReply ON :: StandaloneCommandClient (Maybe RespData))
      awaitSent sentEvent `shouldReturn` Just (commandBytes ["CLIENT", "REPLY", "ON"])
      putMVar replies "+OK\r\n"
      takeMVar restored >>= \result -> case result of
        Right (Just (RespSimpleString "OK")) -> return ()
        _                                     -> expectationFailure "CLIENT REPLY ON did not consume its reply"
      closeStandaloneClient client

    it "keeps OFF and restoration usable on a dedicated sequential connection" $ do
      closeCount <- newIORef 0
      replies <- newEmptyMVar
      sent <- newIORef BS.empty
      sentEvent <- newEmptyMVar
      let connection = MockConnected closeCount replies sent sentEvent
      putMVar replies "+OK\r\n"

      restored <- runSequential connection $ do
        _ <- clientReply OFF
        sendWithoutReply ["SET", "filler-key", "filler-value"]
        clientReply ON
      restored `shouldBe` Just (RespSimpleString "OK")
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "OFF"]
          <> commandBytes ["SET", "filler-key", "filler-value"]
          <> commandBytes ["CLIENT", "REPLY", "ON"]

createCommandClient
  :: IO (StandaloneClient, MVar ByteString, IORef ByteString, MVar ByteString)
createCommandClient = do
  closeCount <- newIORef 0
  replies <- newEmptyMVar
  sent <- newIORef BS.empty
  sentEvent <- newEmptyMVar
  client <- createStandaloneClient
    (const $ return $ MockConnected closeCount replies sent sentEvent)
    (NodeAddress "127.0.0.1" 6379)
  return (client, replies, sent, sentEvent)

commandBytes :: [ByteString] -> ByteString
commandBytes =
  LBS.toStrict . Builder.toLazyByteString . encodeCommandBuilder

forkResult
  :: MVar (Either SomeException a)
  -> IO a
  -> IO ()
forkResult result action = do
  _ <- forkIO $ try action >>= putMVar result
  return ()

awaitSent :: MVar ByteString -> IO (Maybe ByteString)
awaitSent = timeout 1000000 . takeMVar

runSequential :: MockClient 'Connected -> RedisCommandClient MockClient a -> IO a
runSequential client action =
  State.evalStateT (runRedisCommandClient action) (ClientState client BS.empty)

sendWithoutReply :: [ByteString] -> RedisCommandClient MockClient ()
sendWithoutReply args = RedisCommandClient $ do
  ClientState client _ <- State.get
  liftIO $ send client (Builder.toLazyByteString (encodeCommandBuilder args))
