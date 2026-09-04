{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import           Control.Concurrent                    (threadDelay)
import           Control.Concurrent.MVar               (MVar, newEmptyMVar,
                                                        putMVar, takeMVar)
import           Control.Exception                     (SomeException, finally,
                                                        fromException, throwIO,
                                                        try)
import           Control.Monad.IO.Class                (liftIO)
import           Data.ByteString                       (ByteString)
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionPhase (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Client.ConnectionSetup (PlaintextSetupOperations (..),
                                                        TLSSetupOperations (..),
                                                        runPlaintextSetup,
                                                        runTLSSetup)
import           Database.Redis.Cluster                (NodeAddress (..))
import           Database.Redis.Connector              (ConnectionSetupException (..),
                                                        ConnectionSupervisor (..),
                                                        clusterPlaintextConnectorWithTimeout,
                                                        withConnectionTimeoutSupervised)
import           Database.Redis.Standalone             (StandaloneConfig (..),
                                                        defaultStandaloneConfig)
import           GHC.Clock                             (getMonotonicTimeNSec)
import           System.Timeout                        (timeout)
import           Test.Hspec

data TestClient (status :: ConnectionStatus) where
  TestConnected :: IORef Int -> TestClient 'Connected

instance Show (TestClient status) where
  show _ = "TestClient"

instance Client TestClient where
  connect = error "TestClient: connect is not supported"
  close = abort
  abort (TestConnected closes) =
    liftIO $ increment closes
  send _ _ = return ()
  receive _ = return (mempty :: ByteString)

data Counters = Counters
  { socketCloses  :: IORef Int
  , contextCloses :: IORef Int
  }

main :: IO ()
main = hspec $ do
  describe "direct connector timeout boundary" $
    it "supports the documented timeout-aware standalone connector" $ do
      let config = defaultStandaloneConfig
            { standaloneConnector =
                clusterPlaintextConnectorWithTimeout 5
            }
      standaloneMultiplexerCount config `shouldBe` 1
  describe "production plaintext setup deadline" $
    mapM_ plaintextTimeoutCase
      [ (DNSResolution, 0)
      , (SocketCreation, 0)
      , (SocketConfiguration, 1)
      , (TCPConnection, 1)
      ]
  describe "production TLS setup deadline" $
    mapM_ tlsTimeoutCase
      [ (DNSResolution, 0, 0)
      , (SocketCreation, 0, 0)
      , (SocketConfiguration, 1, 0)
      , (TCPConnection, 1, 0)
      , (TLSContextCreation, 1, 0)
      , (TLSHandshake, 1, 1)
      ]
  describe "production TLS synchronous failure" $
    it "closes the context and socket exactly once after handshake failure" $ do
      counters <- newCounters
      started <- newEmptyMVar
      release <- newEmptyMVar
      let operations =
            (tlsOperations counters Authentication started release)
              { tlsRunHandshake =
                  const $ throwIO $ userError "injected TLS handshake failure"
              }
      runTLSSetup
        (const $ return ())
        localTestCleanup
        operations
        `shouldThrow` anyIOException
      readIORef (socketCloses counters) `shouldReturn` 1
      readIORef (contextCloses counters) `shouldReturn` 1

plaintextTimeoutCase :: (ConnectionPhase, Int) -> Spec
plaintextTimeoutCase (stalledPhase, expectedSocketCloses) =
  it ("bounds and cleans " <> show stalledPhase) $ do
    counters <- newCounters
    started <- newEmptyMVar
    release <- newEmptyMVar
    workerFinished <- newEmptyMVar
    let operations = plaintextOperations
          counters stalledPhase started release
        connector supervisor _ =
          runPlaintextSetup
            (setConnectionPhase supervisor)
            (registerSetupCleanup supervisor)
            operations
            `finally` putMVar workerFinished ()
    assertTimeout stalledPhase counters expectedSocketCloses 0
      workerFinished $ withConnectionTimeoutSupervised
        1 DNSResolution connector testNode

tlsTimeoutCase :: (ConnectionPhase, Int, Int) -> Spec
tlsTimeoutCase
    (stalledPhase, expectedSocketCloses, expectedContextCloses) =
  it ("bounds and cleans " <> show stalledPhase) $ do
    counters <- newCounters
    started <- newEmptyMVar
    release <- newEmptyMVar
    workerFinished <- newEmptyMVar
    let operations = tlsOperations
          counters stalledPhase started release
        connector supervisor _ =
          runTLSSetup
            (setConnectionPhase supervisor)
            (registerSetupCleanup supervisor)
            operations
            `finally` putMVar workerFinished ()
    assertTimeout stalledPhase counters
      expectedSocketCloses expectedContextCloses workerFinished $
        withConnectionTimeoutSupervised
          1 DNSResolution connector testNode

assertTimeout
  :: ConnectionPhase
  -> Counters
  -> Int
  -> Int
  -> MVar ()
  -> IO (TestClient 'Connected)
  -> Expectation
assertTimeout expectedPhase counters expectedSocketCloses
    expectedContextCloses workerFinished action = do
  startedAt <- getMonotonicTimeNSec
  result <- try action :: IO (Either SomeException (TestClient 'Connected))
  finishedAt <- getMonotonicTimeNSec
  let elapsed =
        fromIntegral (finishedAt - startedAt) / 1000000000 :: Double
  result `shouldSatisfy` \case
    Left err ->
      case fromExceptionTimeout err of
        Just timeoutError ->
          connectionTimeoutPhase timeoutError == expectedPhase
            && connectionTimeoutEndpoint timeoutError == testNode
        Nothing -> False
    Right _ -> False
  elapsed `shouldSatisfy` \seconds ->
    seconds >= 0.75 && seconds < 2.5
  timeout 1000000 (takeMVar workerFinished) `shouldReturn` Just ()
  awaitExpected (socketCloses counters) expectedSocketCloses
  awaitExpected (contextCloses counters) expectedContextCloses
  readIORef (socketCloses counters) `shouldReturn` expectedSocketCloses
  readIORef (contextCloses counters) `shouldReturn` expectedContextCloses

fromExceptionTimeout :: SomeException -> Maybe ConnectionSetupException
fromExceptionTimeout = fromException

plaintextOperations
  :: Counters
  -> ConnectionPhase
  -> MVar ()
  -> MVar ()
  -> PlaintextSetupOperations Int Int (TestClient 'Connected)
plaintextOperations counters stalledPhase started release =
  PlaintextSetupOperations
    { plaintextResolve = stall DNSResolution $ return 1
    , plaintextOpenSocket = stall SocketCreation $ return 2
    , plaintextConfigureSocket =
        \_ -> stall SocketConfiguration $ return ()
    , plaintextConnectSocket =
        \_ _ -> stall TCPConnection $ return ()
    , plaintextCloseSocket = const $ increment $ socketCloses counters
    , plaintextConnected = \_ _ _ ->
        TestConnected $ socketCloses counters
    }
  where
    stall :: ConnectionPhase -> IO a -> IO a
    stall phase = stallAt stalledPhase phase started release

tlsOperations
  :: Counters
  -> ConnectionPhase
  -> MVar ()
  -> MVar ()
  -> TLSSetupOperations Int Int () Int (TestClient 'Connected)
tlsOperations counters stalledPhase started release =
  TLSSetupOperations
    { tlsResolve = stall DNSResolution $ return 1
    , tlsOpenSocket = stall SocketCreation $ return 2
    , tlsConfigureSocket =
        \_ -> stall SocketConfiguration $ return ()
    , tlsConnectSocket =
        \_ _ -> stall TCPConnection $ return ()
    , tlsCloseSocket = const $ increment $ socketCloses counters
    , tlsLoadStore = return ()
    , tlsCreateContext =
        \_ _ -> stall TLSContextCreation $ return 3
    , tlsCloseContext = const $ increment $ contextCloses counters
    , tlsRunHandshake =
        \_ -> stall TLSHandshake $ return ()
    , tlsConnected = \_ _ _ _ ->
        TestConnected $ socketCloses counters
    }
  where
    stall :: ConnectionPhase -> IO a -> IO a
    stall phase = stallAt stalledPhase phase started release

stallAt
  :: ConnectionPhase
  -> ConnectionPhase
  -> MVar ()
  -> MVar ()
  -> IO a
  -> IO a
stallAt selected current started release action
  | selected == current = putMVar started () >> takeMVar release >> action
  | otherwise = action

newCounters :: IO Counters
newCounters =
  Counters <$> newIORef 0 <*> newIORef 0

increment :: IORef Int -> IO ()
increment ref =
  atomicModifyIORef' ref $ \count -> (count + 1, ())

localTestCleanup :: IO () -> IO (IO ())
localTestCleanup cleanup = do
  finalized <- newIORef False
  return $ do
    shouldRun <- atomicModifyIORef' finalized $ \done ->
      (True, not done)
    if shouldRun then cleanup else return ()

awaitExpected :: IORef Int -> Int -> IO ()
awaitExpected _ 0 = return ()
awaitExpected ref expected =
  timeout 1000000 loop `shouldReturn` Just ()
  where
    loop = do
      actual <- readIORef ref
      if actual == expected
        then return ()
        else threadDelay 1000 >> loop

testNode :: NodeAddress
testNode = NodeAddress "redis.test" 6379
