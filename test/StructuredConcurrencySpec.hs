{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           ClusterFiller                         (executeClusterFillJob,
                                                        fillClusterWithData,
                                                        fillNodeWithDataWithTimeout,
                                                        withClusterFillClient,
                                                        withClusterFillConnection)
import           Control.Concurrent.Async              (Async, async, cancel,
                                                        waitCatch)
import           Control.Concurrent.MVar               (newMVar)
import           Control.Concurrent.STM                (TMVar, TVar, atomically,
                                                        check, modifyTVar',
                                                        newEmptyTMVarIO,
                                                        newTVarIO, putTMVar,
                                                        readTMVar, readTVar,
                                                        readTVarIO, retry)
import           Control.Exception                     (SomeException,
                                                        fromException, throwIO,
                                                        try)
import           Control.Monad                         (when)
import           Control.Monad.IO.Class                (liftIO)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Lazy                  as LBS
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef,
                                                        writeIORef)
import           Data.List                             (isInfixOf)
import qualified Data.Map.Strict                       as Map
import qualified Data.Set                              as Set
import           Data.Time.Clock                       (getCurrentTime)
import qualified Data.Vector                           as V
import           Data.Word                             (Word16)
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..),
                                                        SlotRange (..))
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterConfig (..))
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..))
import qualified Database.Redis.Cluster.ConnectionPool as CP
import           Database.Redis.Internal.MultiplexPool (createMultiplexPool)
import           ProcessLifecycle                      (ChildProcessFailure (..),
                                                        waitForChildProcesses)
import           StructuredConcurrency                 (ConcurrentFailure (..),
                                                        runConcurrentlyFailFast)
import           System.Exit                           (ExitCode (ExitFailure))
import           System.Process                        (createProcess,
                                                        getProcessExitCode,
                                                        proc)
import           System.Timeout                        (timeout)
import           Test.Hspec

diagnosticTimeout :: Int
diagnosticTimeout = 5000000

main :: IO ()
main = hspec $ do
  describe "structured worker ownership" $ do
    it "cancels and closes a real blocked sibling before surfacing the body failure" $ do
      tracker <- newTracker
      release <- newPhase
      let primaryConnector =
            trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally
          siblingConnector =
            trackedConnector tracker WorkerTransport False SendBlocked ReceiveNormally
      parent <- async $ runConcurrentlyFailFast
        [ withClusterFillConnection primaryConnector testAddress $ \_ -> do
            awaitPhase release
            throwIO $ userError "primary body failure"
        , withClusterFillConnection siblingConnector testAddress $ \conn ->
            send conn LBS.empty
        ]
      awaitRoleAcquired tracker WorkerTransport 2
      awaitSendCount tracker 1
      signalPhase release
      result <- awaitResult parent
      show result `shouldSatisfy` isInfixOf "primary body failure"
      assertAllConnectionsClosedOnce tracker 2

    it "preserves a body failure and reports a real sibling transport close failure" $ do
      tracker <- newTracker
      release <- newPhase
      let primaryConnector =
            trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally
          siblingConnector =
            trackedConnector tracker WorkerTransport True SendBlocked ReceiveNormally
      parent <- async $ runConcurrentlyFailFast
        [ withClusterFillConnection primaryConnector testAddress $ \_ -> do
            awaitPhase release
            throwIO $ userError "send failure"
        , withClusterFillConnection siblingConnector testAddress $ \conn ->
            send conn LBS.empty
        ]
      awaitRoleAcquired tracker WorkerTransport 2
      awaitSendCount tracker 1
      signalPhase release
      result <- awaitResult parent
      assertConcurrentFailure "send failure" 1 result
      assertAllConnectionsClosedOnce tracker 2

    it "reports every real sibling transport cleanup failure" $ do
      tracker <- newTracker
      release <- newPhase
      let primaryConnector =
            trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally
          failingSiblingConnector =
            trackedConnector tracker WorkerTransport True SendBlocked ReceiveNormally
      parent <- async $ runConcurrentlyFailFast
        [ withClusterFillConnection primaryConnector testAddress $ \_ -> do
            awaitPhase release
            throwIO $ userError "primary body failure"
        , withClusterFillConnection failingSiblingConnector testAddress $ \conn ->
            send conn LBS.empty
        , withClusterFillConnection failingSiblingConnector testAddress $ \conn ->
            send conn LBS.empty
        ]
      awaitRoleAcquired tracker WorkerTransport 3
      awaitSendCount tracker 2
      signalPhase release
      result <- awaitResult parent
      assertConcurrentFailure "primary body failure" 2 result
      assertAllConnectionsClosedOnce tracker 3

  describe "cluster fill worker connection ownership" $ do
    it "closes an acquired direct transport exactly once after success" $ do
      tracker <- newTracker
      withClusterFillConnection
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally)
        testAddress $ \conn ->
          send conn LBS.empty
      assertAllConnectionsClosedOnce tracker 1

    it "surfaces acquisition failure without inventing an owned transport" $ do
      tracker <- newTracker
      topology <- populatedTopology
      result <- withSyntheticClusterClient tracker topology
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally) False $ \client ->
          try (executeClusterFillJob client failingConnector testSlotRanges 1 8 8 65536
            (testAddress, 0, 1)) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "acquire failure"
      assertAllConnectionsClosedOnce tracker 0

    it "closes the production worker transport when live topology loses its node" $ do
      tracker <- newTracker
      topology <- emptyTopology
      result <- withSyntheticClusterClient tracker topology
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally) False $ \client ->
          try (executeClusterFillJob client (trackedWorkerConnector tracker)
            testSlotRanges 1 8 8 65536 (testAddress, 0, 1)) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "lost its assigned node"
      assertAllConnectionsClosedOnce tracker 1

    it "closes the production worker transport when its node has no assigned slots" $ do
      tracker <- newTracker
      topology <- populatedTopology
      result <- withSyntheticClusterClient tracker topology
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally) False $ \client ->
          try (executeClusterFillJob client (trackedWorkerConnector tracker)
            Map.empty 1 8 8 65536 (testAddress, 0, 1)) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "found no slots"
      assertAllConnectionsClosedOnce tracker 1

    it "closes the production worker transport after a send/body failure" $ do
      tracker <- newTracker
      topology <- populatedTopology
      let connector =
            trackedConnector tracker WorkerTransport False
              (SendFailure "send failure") ReceiveNormally
      result <- withSyntheticClusterClient tracker topology connector False $ \client ->
        try (executeClusterFillJob client connector testSlotRanges 1 8 8 65536
          (testAddress, 0, 1)) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "send failure"
      assertAllConnectionsClosedOnce tracker 1

    it "uses bracket cleanup precedence when worker body and close both fail" $ do
      tracker <- newTracker
      topology <- populatedTopology
      let connector =
            trackedConnector tracker WorkerTransport True
              (SendFailure "body failure") ReceiveNormally
      result <- withSyntheticClusterClient tracker topology connector False $ \client ->
        try (executeClusterFillJob client connector testSlotRanges 1 8 8 65536
          (testAddress, 0, 1)) :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "close failure"
      show result `shouldNotSatisfy` isInfixOf "body failure"
      assertAllConnectionsClosedOnce tracker 1

    it "times out through the production fill worker and closes the transport" $ do
      tracker <- newTracker
      result <- try (withClusterFillConnection
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveBlocked)
        testAddress $ \conn ->
          fillNodeWithDataWithTimeout 1 conn [0] 1 1 0 8 8 65536)
        :: IO (Either SomeException ())
      show result `shouldSatisfy` isInfixOf "timed out"
      assertAllConnectionsClosedOnce tracker 1

    it "rejects use of a production-scoped transport after it has closed" $ do
      tracker <- newTracker
      escaped <- newIORef Nothing
      withClusterFillConnection
        (trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally)
        testAddress $ \conn ->
          writeIORef escaped (Just conn)
      Just conn <- readIORef escaped
      send conn LBS.empty `shouldThrow` anyException
      assertAllConnectionsClosedOnce tracker 1

  describe "cluster fill parent ownership" $ do
    it "closes the real parent pool and failed worker transport exactly once" $ do
      tracker <- newTracker
      topology <- populatedTopology
      let connector =
            trackedConnector tracker WorkerTransport False
              (SendFailure "worker body failure") ReceiveNormally
      result <- try $ withSyntheticClusterClient tracker topology connector True $ \client ->
        executeClusterFillJob client connector testSlotRanges 1 8 8 65536
          (testAddress, 0, 1)
      show (result :: Either SomeException ()) `shouldSatisfy`
        isInfixOf "worker body failure"
      assertRoleClosedOnce tracker ParentPoolTransport 1
      assertRoleClosedOnce tracker WorkerTransport 1
      assertAllConnectionsClosedOnce tracker 2

    it "cancels active workers before closing the real parent pool exactly once" $ do
      tracker <- newTracker
      topology <- populatedTopology
      let connector =
            trackedConnector tracker WorkerTransport False SendBlocked ReceiveNormally
      parent <- async $ withSyntheticClusterClient tracker topology connector True $ \client ->
        fillClusterWithData client connector 1 2 1 8 8 65536
      awaitRoleAcquired tracker ParentPoolTransport 1
      awaitRoleAcquired tracker WorkerTransport 2
      awaitSendCount tracker 2
      cancel parent
      result <- awaitResult parent
      result `shouldSatisfy` isFailure
      assertRoleClosedOnce tracker ParentPoolTransport 1
      assertRoleClosedOnce tracker WorkerTransport 2
      assertAllConnectionsClosedOnce tracker 3

  describe "multiprocess fill ownership" $
    it "waits and reaps every real child before selecting the first indexed failure" $ do
      (_, _, _, firstChild) <- createProcess (proc "/bin/sh" ["-c", "exit 7"])
      (_, _, _, secondChild) <- createProcess
        (proc "/bin/sh" ["-c", "sleep 0.2; exit 9"])
      bounded <- timeout diagnosticTimeout
        (try (waitForChildProcesses [firstChild, secondChild])
          :: IO (Either SomeException ()))
      case bounded of
        Nothing -> expectationFailure "child wait exceeded diagnostic bound"
        Just (Left exception) ->
          case fromException exception :: Maybe ChildProcessFailure of
            Nothing -> expectationFailure $ "unexpected result: " ++ show exception
            Just (ChildProcessFailure index exitCode) -> do
              index `shouldBe` 0
              exitCode `shouldBe` ExitFailure 7
        Just (Right ()) ->
          expectationFailure "expected a non-zero child exit to fail the parent"
      getProcessExitCode firstChild `shouldReturn` Just (ExitFailure 7)
      getProcessExitCode secondChild `shouldReturn` Just (ExitFailure 9)

newPhase :: IO (TMVar ())
newPhase = newEmptyTMVarIO

signalPhase :: TMVar () -> IO ()
signalPhase phase = atomically $ putTMVar phase ()

awaitPhase :: TMVar () -> IO ()
awaitPhase phase = awaitWithin "phase" $ atomically $ readTMVar phase

awaitResult :: Async () -> IO (Either SomeException ())
awaitResult worker = awaitWithin "worker completion" $ waitCatch worker

awaitRoleAcquired :: Tracker -> TransportRole -> Int -> IO ()
awaitRoleAcquired tracker role expected =
  awaitWithin ("acquiring " ++ show expected ++ " " ++ show role ++ " transports") $
    atomically $ do
      roles <- readTVar (trackerRoles tracker)
      check $ length (filter (== role) $ Map.elems roles) >= expected

awaitSendCount :: Tracker -> Int -> IO ()
awaitSendCount tracker expected =
  awaitWithin ("starting " ++ show expected ++ " sends") $
    atomically $ do
      count <- readTVar (trackerSendCount tracker)
      check $ count >= expected

awaitWithin :: String -> IO a -> IO a
awaitWithin description action = do
  result <- timeout diagnosticTimeout action
  case result of
    Nothing -> expectationFailure (description ++ " exceeded diagnostic bound")
      >> error "unreachable"
    Just value -> pure value

assertConcurrentFailure :: String -> Int -> Either SomeException () -> Expectation
assertConcurrentFailure primary expectedCleanup result =
  case result of
    Left exception ->
      case fromException exception :: Maybe ConcurrentFailure of
        Nothing -> expectationFailure $ "expected ConcurrentFailure, got: " ++ show exception
        Just failure -> do
          show (concurrentPrimaryFailure failure) `shouldSatisfy` isInfixOf primary
          length (concurrentSiblingCleanupFailures failure) `shouldBe` expectedCleanup
    Right () -> expectationFailure "expected worker failure"

isFailure :: Either SomeException () -> Bool
isFailure (Left _)  = True
isFailure (Right _) = False

data TransportRole = ParentPoolTransport | WorkerTransport
  deriving (Eq, Ord, Show)

data SendMode
  = SendNormally
  | SendFailure String
  | SendBlocked

data ReceiveMode
  = ReceiveNormally
  | ReceiveBlocked

data Tracker = Tracker
  { trackerNextId      :: IORef Int
  , trackerLive        :: IORef (Set.Set Int)
  , trackerCloseCounts :: IORef (Map.Map Int Int)
  , trackerRoles       :: TVar (Map.Map Int TransportRole)
  , trackerSendCount   :: TVar Int
  }

data TrackingClient (status :: ConnectionStatus) = TrackingClient
  Tracker
  Int
  Bool
  SendMode
  ReceiveMode

instance Client TrackingClient where
  connect (TrackingClient tracker connectionId closeFails sendMode receiveMode) =
    liftIO (assertOpen tracker connectionId)
      >> pure (TrackingClient tracker connectionId closeFails sendMode receiveMode)

  close (TrackingClient tracker connectionId closeFails _ _) = liftIO $ do
    assertOpen tracker connectionId
    atomicModifyIORef' (trackerLive tracker)
      (\live -> (Set.delete connectionId live, ()))
    atomicModifyIORef' (trackerCloseCounts tracker)
      (\counts -> (Map.insertWith (+) connectionId 1 counts, ()))
    when closeFails $ throwIO $ userError "close failure"

  abort = close

  send (TrackingClient tracker connectionId _ sendMode _) _ = liftIO $ do
    assertOpen tracker connectionId
    atomically $ modifyTVar' (trackerSendCount tracker) (+ 1)
    case sendMode of
      SendNormally       -> pure ()
      SendFailure reason -> throwIO $ userError reason
      SendBlocked        -> atomically retry

  receive (TrackingClient tracker connectionId _ _ receiveMode) = liftIO $ do
    assertOpen tracker connectionId
    case receiveMode of
      ReceiveNormally -> pure "+OK\r\n:0\r\n"
      ReceiveBlocked  -> atomically retry

newTracker :: IO Tracker
newTracker =
  Tracker <$> newIORef 0 <*> newIORef Set.empty <*> newIORef Map.empty
    <*> newTVarIO Map.empty <*> newTVarIO 0

trackedConnector
  :: Tracker
  -> TransportRole
  -> Bool
  -> SendMode
  -> ReceiveMode
  -> NodeAddress
  -> IO (TrackingClient 'Connected)
trackedConnector tracker role closeFails sendMode receiveMode _ = do
  connectionId <- atomicModifyIORef' (trackerNextId tracker) (\n -> (n + 1, n))
  atomicModifyIORef' (trackerLive tracker)
    (\live -> (Set.insert connectionId live, ()))
  atomically $ modifyTVar' (trackerRoles tracker)
    (Map.insert connectionId role)
  pure $ TrackingClient tracker connectionId closeFails sendMode receiveMode

trackedWorkerConnector
  :: Tracker
  -> NodeAddress
  -> IO (TrackingClient 'Connected)
trackedWorkerConnector tracker =
  trackedConnector tracker WorkerTransport False SendNormally ReceiveNormally

failingConnector :: NodeAddress -> IO (TrackingClient 'Connected)
failingConnector _ = throwIO $ userError "acquire failure"

assertAllConnectionsClosedOnce :: Tracker -> Int -> IO ()
assertAllConnectionsClosedOnce tracker expected = do
  live <- readIORef (trackerLive tracker)
  roles <- readTVarIO (trackerRoles tracker)
  counts <- readIORef (trackerCloseCounts tracker)
  Set.null live `shouldBe` True
  Map.size roles `shouldBe` expected
  Map.size counts `shouldBe` expected
  mapM_ (`shouldBe` 1) (Map.elems counts)

assertRoleClosedOnce :: Tracker -> TransportRole -> Int -> IO ()
assertRoleClosedOnce tracker role expected = do
  roles <- readTVarIO (trackerRoles tracker)
  counts <- readIORef (trackerCloseCounts tracker)
  let connectionIds =
        [ connectionId
        | (connectionId, connectionRole) <- Map.toList roles
        , connectionRole == role
        ]
  length connectionIds `shouldBe` expected
  mapM_ (\connectionId -> Map.lookup connectionId counts `shouldBe` Just 1)
    connectionIds

assertOpen :: Tracker -> Int -> IO ()
assertOpen tracker connectionId = do
  live <- readIORef (trackerLive tracker)
  if Set.member connectionId live
    then pure ()
    else throwIO $ userError "use after close"

withSyntheticClusterClient
  :: Tracker
  -> ClusterTopology
  -> (NodeAddress -> IO (TrackingClient 'Connected))
  -> Bool
  -> (ClusterClient TrackingClient -> IO a)
  -> IO a
withSyntheticClusterClient tracker topology workerConnector populateParent action =
  withClusterFillClient acquire action
  where
    acquire = do
      pool <- CP.createPool testPoolConfig
      when populateParent $
        CP.withConnectionBounded pool testAddress
          (trackedConnector tracker ParentPoolTransport False
            SendNormally ReceiveNormally)
          (\_ -> pure ())
      topologyVar <- newTVarIO topology
      refreshLock <- newMVar ()
      muxPool <- createMultiplexPool workerConnector 1
      pure ClusterClient
        { clusterTopology = topologyVar
        , clusterConnectionPool = pool
        , clusterConfig = testClusterConfig
        , clusterConnector = workerConnector
        , clusterRefreshLock = refreshLock
        , clusterMultiplexPool = muxPool
        }

populatedTopology :: IO ClusterTopology
populatedTopology = do
  currentTime <- getCurrentTime
  pure ClusterTopology
    { topologySlots = V.replicate 16384 testNodeId
    , topologyAddresses = V.replicate 16384 testAddress
    , topologyNodes = Map.singleton testNodeId testNode
    , topologyUpdateTime = currentTime
    }

emptyTopology :: IO ClusterTopology
emptyTopology = do
  currentTime <- getCurrentTime
  pure ClusterTopology
    { topologySlots = V.empty
    , topologyAddresses = V.empty
    , topologyNodes = Map.empty
    , topologyUpdateTime = currentTime
    }

testPoolConfig :: PoolConfig
testPoolConfig = PoolConfig
  { maxConnectionsPerNode = 4
  , connectionTimeout = 1
  , maxRetries = 1
  , useTLS = False
  }

testClusterConfig :: ClusterConfig
testClusterConfig = ClusterConfig
  { clusterSeedNode = testAddress
  , clusterPoolConfig = testPoolConfig
  , clusterMaxRetries = 1
  , clusterRetryDelay = 1
  , clusterTopologyRefreshInterval = 600
  }

testNodeId :: BS.ByteString
testNodeId = "node-1"

testNode :: ClusterNode
testNode = ClusterNode
  { nodeId = testNodeId
  , nodeAddress = testAddress
  , nodeRole = Master
  , nodeSlotsServed = [SlotRange 0 16383 testNodeId []]
  , nodeReplicas = []
  }

testSlotRanges :: Map.Map BS.ByteString [Word16]
testSlotRanges = Map.singleton testNodeId [0]

testAddress :: NodeAddress
testAddress = NodeAddress "tracked.cluster.test" 6379
