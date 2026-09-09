{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent        (forkFinally, forkIO, killThread,
                                            threadDelay)
import           Control.Concurrent.MVar   (MVar, newEmptyMVar, putMVar,
                                            takeMVar, tryPutMVar, tryTakeMVar)
import           Control.Exception         (SomeException, bracket,
                                            displayException, fromException,
                                            throwIO, try)
import           Control.Monad             (forM_, void, when)
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
                                            ClientReplyUncertainWrite (..),
                                            ClientReplyValues (..),
                                            ClientState (..),
                                            RedisCommandClient (..),
                                            RedisCommands (..),
                                            encodeCommandBuilder,
                                            sendClientReplySkipAndCommand,
                                            sendCommandWithoutReply)
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

data SendPhase
  = BeforeFirstByte
  | PartialSkip
  | BetweenSkipAndTarget
  | PartialTarget
  | AfterFullTransfer
  | CompleteTransfer
  deriving (Eq, Show)

data PhaseClient (a :: ConnectionStatus) where
  PhaseConnected
    :: !SendPhase
    -> !(IORef Bool)
    -> !(IORef Int)
    -> !(IORef ByteString)
    -> !(MVar ByteString)
    -> !(Maybe (MVar (), MVar ()))
    -> !Bool
    -> PhaseClient 'Connected

instance Client PhaseClient where
  connect = error "PhaseClient: connect not supported"
  close (PhaseConnected _ closed closeCount _ _ closeGate closeFails) =
    liftIO $ do
      atomicModifyIORef' closeCount $ \count -> (count + 1, ())
      atomicModifyIORef' closed $ \_ -> (True, ())
      case closeGate of
        Nothing -> return ()
        Just (started, release) -> do
          void $ tryPutMVar started ()
          takeMVar release
      when closeFails $ throwIO $ userError "injected close failure"
  send (PhaseConnected phase closed _ sent _ _ _) bytes = liftIO $ do
    isClosed <- readIORef closed
    when isClosed $ throwIO $ userError "attempted to reuse a closed connection"
    let payload = LBS.toStrict bytes
        skip = commandBytes ["CLIENT", "REPLY", "SKIP"]
        target = BS.drop (BS.length skip) payload
        write chunk = atomicModifyIORef' sent $ \old -> (old <> chunk, ())
        failWrite = throwIO $ userError ("injected " <> show phase <> " send failure")
    case phase of
      BeforeFirstByte      -> failWrite
      PartialSkip          -> write (BS.take 1 skip) >> failWrite
      BetweenSkipAndTarget -> write skip >> failWrite
      PartialTarget        -> write (skip <> BS.take 1 target) >> failWrite
      AfterFullTransfer    -> write payload >> failWrite
      CompleteTransfer     -> write payload
  receive (PhaseConnected _ _ _ _ replies _ _) = liftIO $ takeMVar replies

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
    it "uses one-argument AUTH for the default user" $
      expectAuthenticationExchange
        "default"
        "password-secret"
        (commandBytes ["AUTH", "password-secret"])
        "+OK\r\n"
        (RespSimpleString "OK")

    it "uses HELLO 2 AUTH for a named ACL user" $
      expectAuthenticationExchange
        "acl-user"
        "acl-secret"
        (commandBytes ["HELLO", "2", "AUTH", "acl-user", "acl-secret"])
        "*2\r\n$5\r\nproto\r\n:2\r\n"
        (RespArray [RespBulkString "proto", RespInteger 2])

  describe "Standalone CLIENT REPLY protocol" $ do
    it "rejects OFF and SKIP before sending, leaving later commands reply-safe" $ do
      (client, replies, sent, sentEvent) <- createCommandClient
      forM_ [OFF, SKIP, SKIP] $ \mode -> do
        result <- try $ runStandaloneClient client
          (clientReply mode :: StandaloneCommandClient (Maybe RespData))
          :: IO (Either ClientReplyModeUnsupported (Maybe RespData))
        result `shouldBe` Left (ClientReplyModeUnsupported mode)
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
        sendCommandWithoutReply ["SET", "filler-key", "filler-value"]
        clientReply ON
      restored `shouldBe` Just (RespSimpleString "OK")
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "OFF"]
          <> commandBytes ["SET", "filler-key", "filler-value"]
          <> commandBytes ["CLIENT", "REPLY", "ON"]
      putMVar replies "+PONG\r\n"
      pinged <- runSequential connection (ping :: RedisCommandClient MockClient RespData)
      pinged `shouldBe` RespSimpleString "PONG"
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "OFF"]
          <> commandBytes ["SET", "filler-key", "filler-value"]
          <> commandBytes ["CLIENT", "REPLY", "ON"]
          <> commandBytes ["PING"]

    it "binds SKIP to its target and preserves the following response" $ do
      closeCount <- newIORef 0
      replies <- newEmptyMVar
      sent <- newIORef BS.empty
      sentEvent <- newEmptyMVar
      let connection = MockConnected closeCount replies sent sentEvent
      putMVar replies "+PONG\r\n"

      response <- runSequential connection $ do
        sendClientReplySkipAndCommand ["PING"]
        ping
      response `shouldBe` (RespSimpleString "PONG" :: RespData)
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "SKIP"]
          <> commandBytes ["PING"]
          <> commandBytes ["PING"]

    it "keeps a following error response aligned after a skipped error target" $ do
      closeCount <- newIORef 0
      replies <- newEmptyMVar
      sent <- newIORef BS.empty
      sentEvent <- newEmptyMVar
      let connection = MockConnected closeCount replies sent sentEvent
      putMVar replies "-ERR following command failed\r\n"

      response <- runSequential connection $ do
        sendClientReplySkipAndCommand ["NOT-A-REDIS-COMMAND"]
        ping
      response `shouldBe` (RespError "ERR following command failed" :: RespData)
      readIORef sent `shouldReturn`
        commandBytes ["CLIENT", "REPLY", "SKIP"]
          <> commandBytes ["NOT-A-REDIS-COMMAND"]
          <> commandBytes ["PING"]

  describe "CLIENT REPLY SKIP uncertain transfer safety" $ do
    forM_
      [ (BeforeFirstByte, BS.empty)
      , (PartialSkip, BS.take 1 (commandBytes ["CLIENT", "REPLY", "SKIP"]))
      , (BetweenSkipAndTarget, commandBytes ["CLIENT", "REPLY", "SKIP"])
      , ( PartialTarget
        , commandBytes ["CLIENT", "REPLY", "SKIP"]
            <> BS.take 1 (commandBytes ["PING"])
        )
      , ( AfterFullTransfer
        , commandBytes ["CLIENT", "REPLY", "SKIP"] <> commandBytes ["PING"]
        )
      ] $ \(phase, expectedBytes) ->
        it ("closes once after " <> show phase) $ do
          (connection, sent, closeCount, _) <- createPhaseClient phase Nothing False
          result <- try $ runSequential connection $
            sendClientReplySkipAndCommand ["PING"]
          result `shouldSatisfy` isFailure
          readIORef sent `shouldReturn` expectedBytes
          readIORef closeCount `shouldReturn` 1

    it "fails closed on the old identity and aligns a reconnect response" $ do
      (failedConnection, sent, closeCount, _) <-
        createPhaseClient PartialTarget Nothing False
      firstResult <- try $ runSequential failedConnection $
        sendClientReplySkipAndCommand ["PING"]
      firstResult `shouldSatisfy` isFailure
      readIORef closeCount `shouldReturn` 1
      bytesBeforeReuse <- readIORef sent

      oldIdentity <- try $ runSequential failedConnection
        (ping :: RedisCommandClient PhaseClient RespData)
      oldIdentity `shouldSatisfy` isFailure
      readIORef sent `shouldReturn` bytesBeforeReuse
      readIORef closeCount `shouldReturn` 1

      (replacement, replacementSent, replacementCloseCount, replacementReplies) <-
        createPhaseClient CompleteTransfer Nothing False
      putMVar replacementReplies "+PONG\r\n"
      runSequential replacement (ping :: RedisCommandClient PhaseClient RespData)
        `shouldReturn` RespSimpleString "PONG"
      readIORef replacementSent `shouldReturn` commandBytes ["PING"]
      readIORef replacementCloseCount `shouldReturn` 0

    it "retains the primary write failure when close also fails" $ do
      (connection, _, closeCount, _) <-
        createPhaseClient BeforeFirstByte Nothing True
      result <- try $ runSequential connection $
        sendClientReplySkipAndCommand ["PING"]
      case result of
        Left failure -> do
          let uncertain = fromException failure :: Maybe ClientReplyUncertainWrite
          case uncertain of
            Just details -> do
              displayException (clientReplyPrimaryError details)
                `shouldContain` "injected BeforeFirstByte send failure"
              displayException (clientReplyCloseError details)
                `shouldContain` "injected close failure"
            Nothing -> expectationFailure "write and close failure was not retained"
        Right () -> expectationFailure "uncertain write unexpectedly succeeded"
      readIORef closeCount `shouldReturn` 1

    it "closes exactly once when cancellation races a blocked teardown" $ do
      closeStarted <- newEmptyMVar
      releaseClose <- newEmptyMVar
      (connection, _, closeCount, _) <- createPhaseClient
        AfterFullTransfer (Just (closeStarted, releaseClose)) False
      completed <- newEmptyMVar
      worker <- forkFinally
        (runSequential connection $ sendClientReplySkipAndCommand ["PING"])
        (putMVar completed)
      timeout 1000000 (takeMVar closeStarted) `shouldReturn` Just ()
      cancellationReturned <- newEmptyMVar
      _ <- forkIO $ killThread worker >> putMVar cancellationReturned ()
      threadDelay 10000
      putMVar releaseClose ()
      result <- timeout 1000000 (takeMVar completed)
      result `shouldSatisfy` maybe False isFailure
      timeout 1000000 (takeMVar cancellationReturned) `shouldReturn` Just ()
      readIORef closeCount `shouldReturn` 1

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

expectAuthenticationExchange
  :: ByteString
  -> ByteString
  -> ByteString
  -> ByteString
  -> RespData
  -> IO ()
expectAuthenticationExchange username password expectedBytes reply expectedResponse =
  bracket createCommandClient closeCommandClient $
    \(client, replies, sent, sentEvent) -> do
      completed <- newEmptyMVar
      bracket
        (forkFinally
          (runStandaloneClient client
            (auth username password :: StandaloneCommandClient RespData))
          (putMVar completed))
        killThread $
        \_ -> do
          awaitSent sentEvent `shouldReturn` Just expectedBytes
          readIORef sent `shouldReturn` expectedBytes
          putMVar replies reply
          result <- timeout 1000000 (takeMVar completed)
          case result of
            Just (Right response) -> response `shouldBe` expectedResponse
            Just (Left failure) ->
              expectationFailure $
                "authentication failed: " <> displayException failure
            Nothing -> expectationFailure "authentication did not complete"
  where
    closeCommandClient (client, _, _, _) = closeStandaloneClient client

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

runSequential
  :: (Client client)
  => client 'Connected
  -> RedisCommandClient client a
  -> IO a
runSequential client action =
  State.evalStateT (runRedisCommandClient action) (ClientState client BS.empty)

createPhaseClient
  :: SendPhase
  -> Maybe (MVar (), MVar ())
  -> Bool
  -> IO
       ( PhaseClient 'Connected
       , IORef ByteString
       , IORef Int
       , MVar ByteString
       )
createPhaseClient phase closeGate closeFails = do
  closed <- newIORef False
  closeCount <- newIORef 0
  sent <- newIORef BS.empty
  replies <- newEmptyMVar
  return
    ( PhaseConnected phase closed closeCount sent replies closeGate closeFails
    , sent
    , closeCount
    , replies
    )

isFailure :: Either SomeException a -> Bool
isFailure (Left _)  = True
isFailure (Right _) = False
