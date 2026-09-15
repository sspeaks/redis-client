{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import qualified AppConfig                             as App
import           ClusterSetup                          (createClusterClientFromStateWithMuxCount,
                                                        createPlaintextConnector,
                                                        createTLSConnector)
import           Control.Concurrent                    (ThreadId, forkIO,
                                                        killThread, threadDelay)
import           Control.Concurrent.Async              (forConcurrently)
import           Control.Concurrent.STM                (readTVarIO)
import           Control.Exception                     (SomeException, bracket,
                                                        bracketOnError, finally,
                                                        try)
import           Control.Monad                         (forM, forM_, unless,
                                                        when)
import qualified Control.Monad.State                   as State
import           Data.Aeson                            (ToJSON, encodeFile,
                                                        object, toJSON, (.=))
import qualified Data.Aeson                            as Aeson
import qualified Data.Attoparsec.ByteString            as AP
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Builder               as Builder
import qualified Data.ByteString.Char8                 as BS8
import qualified Data.ByteString.Lazy                  as LBS
import           Data.Foldable                         (for_)
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        modifyIORef', newIORef,
                                                        readIORef, writeIORef)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import           Data.Time.Clock                       (UTCTime, getCurrentTime)
import           Data.Time.Format.ISO8601              (iso8601Show)
import qualified Data.Vector                           as V
import qualified Data.Vector.Unboxed                   as VU
import qualified Data.Vector.Unboxed.Mutable           as VUM
import           Data.Version                          (showVersion)
import           Data.Word                             (Word64, Word8)
import           Database.Redis.Client                 (Client)
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..),
                                                        calculateSlot,
                                                        findNodeAddressForSlot)
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        closeClusterClient)
import           Database.Redis.Command                (ClientState (..),
                                                        encodeGetBuilder,
                                                        encodeSetBuilder,
                                                        runRedisCommandClient)
import           Database.Redis.Connector              (Connector)
import           Database.Redis.Internal.Multiplexer   (Multiplexer,
                                                        MultiplexerStats (..),
                                                        ResponseSlot, SlotPool,
                                                        createMultiplexerFromConnector,
                                                        createSlotPool,
                                                        destroyMultiplexer,
                                                        readMultiplexerStats,
                                                        submitCommandAsync,
                                                        waitSlot)
import           Database.Redis.Internal.MultiplexPool (getMultiplexPoolMuxStats,
                                                        submitToNodeAsync,
                                                        waitSlotResult)
import           Database.Redis.Resp                   (RespData (..),
                                                        parseRespData)
import           GHC.Clock                             (getMonotonicTimeNSec)
import           GHC.Conc                              (getNumCapabilities)
import           GHC.Generics                          (Generic)
import           GHC.RTS.Flags                         (GCFlags (..),
                                                        ParFlags (..),
                                                        RTSFlags (..),
                                                        getRTSFlags)
import           GHC.Stats                             (GCDetails (..),
                                                        RTSStats (..),
                                                        getRTSStats,
                                                        getRTSStatsEnabled)
import           Network.Socket                        (AddrInfo (..),
                                                        AddrInfoFlag (AI_PASSIVE),
                                                        Family (AF_INET),
                                                        SockAddr (..), Socket,
                                                        SocketOption (ReuseAddr),
                                                        SocketType (Stream),
                                                        accept, bind, close,
                                                        defaultHints,
                                                        defaultProtocol,
                                                        getAddrInfo,
                                                        getSocketName, listen,
                                                        setSocketOption, socket)
import qualified Network.Socket.ByteString             as NSB
import           System.Console.GetOpt                 (ArgDescr (..),
                                                        ArgOrder (Permute),
                                                        OptDescr (Option),
                                                        getOpt)
import           System.Environment                    (getArgs, lookupEnv)
import           System.Info                           (arch, compilerName,
                                                        compilerVersion, os)
import           System.Mem                            (performGC)
import           System.Timeout                        (timeout)
import           Text.Read                             (readMaybe)

data Scenario
  = ScenarioStandalone
  | ScenarioCluster
  | ScenarioSlowServer
  deriving (Eq, Show, Generic)

instance ToJSON Scenario where
  toJSON = toJSON . \case
    ScenarioStandalone -> "standalone" :: String
    ScenarioCluster -> "cluster"
    ScenarioSlowServer -> "slow-server"

data Operation
  = OperationSet
  | OperationGet
  | OperationMixed
  | OperationPing
  deriving (Eq, Show, Generic)

instance ToJSON Operation where
  toJSON = toJSON . \case
    OperationSet -> "set" :: String
    OperationGet -> "get"
    OperationMixed -> "mixed"
    OperationPing -> "ping"

data BenchOptions = BenchOptions
  { benchScenario           :: !Scenario
  , benchHost               :: !String
  , benchPort               :: !(Maybe Int)
  , benchUseTLS             :: !Bool
  , benchUsername           :: !String
  , benchAllowInsecureAuth  :: !Bool
  , benchDurationSeconds    :: !Int
  , benchWarmupSeconds      :: !Int
  , benchConcurrency        :: !Int
  , benchBatchSize          :: !Int
  , benchMuxCount           :: !Int
  , benchKeySize            :: !Int
  , benchPayloadSize        :: !Int
  , benchOperation          :: !Operation
  , benchTimeoutMs          :: !Int
  , benchOutputPath         :: !(Maybe FilePath)
  , benchResponseDelayMs    :: !Int
  , benchStallAfterRequests :: !(Maybe Int)
  }

defaultBenchOptions :: BenchOptions
defaultBenchOptions =
  BenchOptions
    { benchScenario = ScenarioStandalone
    , benchHost = "127.0.0.1"
    , benchPort = Nothing
    , benchUseTLS = False
    , benchUsername = "default"
    , benchAllowInsecureAuth = False
    , benchDurationSeconds = 10
    , benchWarmupSeconds = 1
    , benchConcurrency = 16
    , benchBatchSize = 64
    , benchMuxCount = 1
    , benchKeySize = 32
    , benchPayloadSize = 256
    , benchOperation = OperationSet
    , benchTimeoutMs = 1000
    , benchOutputPath = Nothing
    , benchResponseDelayMs = 250
    , benchStallAfterRequests = Nothing
    }

data EnvironmentInfo = EnvironmentInfo
  { environmentCapturedAtUtc   :: !String
  , environmentHostname        :: !(Maybe String)
  , environmentOs              :: !String
  , environmentArch            :: !String
  , environmentCompiler        :: !String
  , environmentCompilerVersion :: !String
  , environmentCapabilities    :: !Int
  , environmentRtsStatsEnabled :: !Bool
  , environmentRtsFlags        :: !Aeson.Value
  }
  deriving (Generic)

instance ToJSON EnvironmentInfo

data BackpressureSample = BackpressureSample
  { currentQueuedCommands :: !Int
  , currentInFlight       :: !Int
  }
  deriving (Eq, Show, Generic)

instance ToJSON BackpressureSample

data PressureHighWater = PressureHighWater
  { queueHighWater    :: !Int
  , inFlightHighWater :: !Int
  }
  deriving (Eq, Show, Generic)

instance ToJSON PressureHighWater

data BenchmarkResult = BenchmarkResult
  { resultScenario             :: !Scenario
  , resultOperation            :: !Operation
  , resultStartedAtUtc         :: !String
  , resultElapsedSeconds       :: !Double
  , resultConfig               :: !Aeson.Value
  , resultEnvironment          :: !EnvironmentInfo
  , resultAttemptedOps         :: !Int
  , resultSuccessfulOps        :: !Int
  , resultErrors               :: !Int
  , resultTimeouts             :: !Int
  , resultOpsPerSecond         :: !Double
  , resultLatencyMicros        :: !Aeson.Value
  , resultAllocationBytesPerOp :: !Double
  , resultPeakResidencyBytes   :: !Integer
  , resultPeakMemoryBytes      :: !Integer
  , resultPostGcLiveBytes      :: !Integer
  , resultGcCpuPercent         :: !Double
  , resultGcs                  :: !Int
  , resultMajorGcs             :: !Int
  , resultBackpressure         :: !PressureHighWater
  }

instance ToJSON BenchmarkResult where
  toJSON result =
    object
      [ "schema_version" .= (1 :: Int)
      , "scenario" .= resultScenario result
      , "operation" .= resultOperation result
      , "started_at_utc" .= resultStartedAtUtc result
      , "elapsed_seconds" .= resultElapsedSeconds result
      , "config" .= resultConfig result
      , "environment" .= resultEnvironment result
      , "metrics" .= object
          [ "attempted_ops" .= resultAttemptedOps result
          , "successful_ops" .= resultSuccessfulOps result
          , "errors" .= resultErrors result
          , "timeouts" .= resultTimeouts result
          , "ops_per_second" .= resultOpsPerSecond result
          , "latency_micros" .= resultLatencyMicros result
          , "allocation_bytes_per_op" .= resultAllocationBytesPerOp result
          , "peak_residency_bytes" .= resultPeakResidencyBytes result
          , "peak_memory_bytes" .= resultPeakMemoryBytes result
          , "post_gc_live_bytes" .= resultPostGcLiveBytes result
          , "gc_cpu_percent" .= resultGcCpuPercent result
          , "gcs" .= resultGcs result
          , "major_gcs" .= resultMajorGcs result
          , "queue_high_water" .= queueHighWater (resultBackpressure result)
          , "in_flight_high_water" .= inFlightHighWater (resultBackpressure result)
          ]
      ]

data ExpectedResponse
  = ExpectSimpleString !BS.ByteString
  | ExpectBulkString !BS.ByteString

data RequestPlan = RequestPlan
  { requestKey      :: !BS.ByteString
  , requestFrame    :: !Builder.Builder
  , requestExpected :: !ExpectedResponse
  }

data Runtime = Runtime
  { runtimeSubmitAsync   :: RequestPlan -> IO ResponseSlot
  , runtimeWait          :: ResponseSlot -> IO RespData
  , runtimeSnapshotStats :: IO [MultiplexerStats]
  , runtimePrepopulate   :: [(BS.ByteString, BS.ByteString)] -> IO ()
  }

data WorkerResult = WorkerResult
  { workerAttempted  :: !Int
  , workerSuccessful :: !Int
  , workerErrors     :: !Int
  , workerTimeouts   :: !Int
  , workerHistogram  :: !(VU.Vector Int)
  }

data PendingSubmission
  = Submitted !Word64 !RequestPlan !ResponseSlot
  | SubmissionFailed

data PressureSampler = PressureSampler
  { samplerStopRef       :: !(IORef Bool)
  , samplerQueueHighRef  :: !(IORef Int)
  , samplerFlightHighRef :: !(IORef Int)
  , samplerThreadId      :: !ThreadId
  }

data SlowServer = SlowServer
  { slowServerSocket :: !Socket
  , slowServerThread :: !ThreadId
  , slowServerPort   :: !Int
  }

main :: IO ()
main = do
  args <- getArgs
  options <- parseArgs args
  statsEnabled <- getRTSStatsEnabled
  unless statsEnabled $
    fail "Run with +RTS -T -RTS so the benchmark can collect RTS residency metrics."
  environment <- captureEnvironment
  startedAt <- getCurrentTime
  runState <- App.resolveRunStateCredentials (toRunState options)
  result <-
    case benchScenario options of
      ScenarioStandalone ->
        withStandaloneRuntime options runState $ \runtime ->
          runBenchmark startedAt environment options runtime
      ScenarioCluster ->
        withClusterRuntime options runState $ \runtime ->
          runBenchmark startedAt environment options runtime
      ScenarioSlowServer ->
        withSlowServer options $ \slowPort -> do
          let slowOptions =
                options
                  { benchHost = "127.0.0.1"
                  , benchPort = Just slowPort
                  , benchUseTLS = False
                  , benchOperation = OperationPing
                  }
          withStandaloneRuntime slowOptions (toRunState slowOptions) $ \runtime ->
            runBenchmark startedAt environment slowOptions runtime
  LBS.putStr (Aeson.encode result)
  putStrLn ""
  for_ (benchOutputPath options) $ \path -> encodeFile path result

runBenchmark
  :: UTCTime
  -> EnvironmentInfo
  -> BenchOptions
  -> Runtime
  -> IO BenchmarkResult
runBenchmark startedAt environment options runtime = do
  prepopulateIfNeeded runtime options
  warmupIfNeeded runtime options
  performGC
  before <- getRTSStats
  startNs <- getMonotonicTimeNSec
  sampler <- startPressureSampler runtime
  workers <- forConcurrently [0 .. benchConcurrency options - 1] $
    runWorker runtime options startNs
  pressure <- stopPressureSampler sampler
  endNs <- getMonotonicTimeNSec
  performGC
  after <- getRTSStats
  let merged = mergeWorkerResults workers
      elapsedSeconds = nanosToSeconds (endNs - startNs)
      attemptedForRatio = max 1 (workerAttempted merged)
  pure $
    BenchmarkResult
      { resultScenario = benchScenario options
      , resultOperation = benchOperation options
      , resultStartedAtUtc = iso8601Show startedAt
      , resultElapsedSeconds = elapsedSeconds
      , resultConfig = configJson options
      , resultEnvironment = environment
      , resultAttemptedOps = workerAttempted merged
      , resultSuccessfulOps = workerSuccessful merged
      , resultErrors = workerErrors merged
      , resultTimeouts = workerTimeouts merged
      , resultOpsPerSecond = fromIntegral (workerSuccessful merged) / elapsedSeconds
      , resultLatencyMicros = histogramPercentiles (workerHistogram merged)
      , resultAllocationBytesPerOp =
          fromIntegral (allocated_bytes after - allocated_bytes before)
            / fromIntegral attemptedForRatio
      , resultPeakResidencyBytes = fromIntegral (max_live_bytes after)
      , resultPeakMemoryBytes = fromIntegral (max_mem_in_use_bytes after)
      , resultPostGcLiveBytes = fromIntegral (gcdetails_live_bytes $ gc after)
      , resultGcCpuPercent = gcCpuPercent before after
      , resultGcs = fromIntegral (gcs after - gcs before)
      , resultMajorGcs = fromIntegral (major_gcs after - major_gcs before)
      , resultBackpressure = pressure
      }

configJson :: BenchOptions -> Aeson.Value
configJson options =
  object
    [ "host" .= benchHost options
    , "port" .= effectivePort options
    , "tls" .= benchUseTLS options
    , "duration_seconds" .= benchDurationSeconds options
    , "warmup_seconds" .= benchWarmupSeconds options
    , "concurrency" .= benchConcurrency options
    , "batch_size" .= benchBatchSize options
    , "mux_count" .= benchMuxCount options
    , "key_size_bytes" .= benchKeySize options
    , "payload_size_bytes" .= benchPayloadSize options
    , "timeout_ms" .= benchTimeoutMs options
    , "response_delay_ms" .=
        if benchScenario options == ScenarioSlowServer
          then Just (benchResponseDelayMs options)
          else Nothing :: Maybe Int
    , "stall_after_requests" .=
        if benchScenario options == ScenarioSlowServer
          then benchStallAfterRequests options
          else Nothing :: Maybe Int
    ]

prepopulateIfNeeded :: Runtime -> BenchOptions -> IO ()
prepopulateIfNeeded runtime options =
  case benchOperation options of
    OperationGet ->
      runtimePrepopulate runtime prepopulatePairs
    OperationMixed ->
      runtimePrepopulate runtime prepopulatePairs
    _ ->
      pure ()
  where
    prepopulatePairs =
      [ (benchmarkKey (benchKeySize options) "bench:get:" idx, benchmarkValue (benchPayloadSize options) idx)
      | idx <- [0 .. prepopulateItemCount options - 1]
      ]

warmupIfNeeded :: Runtime -> BenchOptions -> IO ()
warmupIfNeeded _ BenchOptions {benchWarmupSeconds = warmupSeconds}
  | warmupSeconds <= 0 = pure ()
warmupIfNeeded runtime options = do
  warmupStart <- getMonotonicTimeNSec
  _ <- forConcurrently [0 .. benchConcurrency options - 1] $
    \workerId -> runWorker runtime options {benchDurationSeconds = benchWarmupSeconds options} warmupStart workerId
  pure ()

runWorker :: Runtime -> BenchOptions -> Word64 -> Int -> IO WorkerResult
runWorker runtime options phaseStartNs workerId = do
  histogram <- newHistogram
  let deadlineNs = phaseStartNs + secondsToNanos (benchDurationSeconds options)
      initialIndex = workerId * 100000000
  loop histogram deadlineNs initialIndex 0 0 0 0
  where
    loop histogram deadlineNs nextIndex attempted successful errors timeoutsSeen = do
      now <- getMonotonicTimeNSec
      if now >= deadlineNs
        then do
          frozen <- freezeHistogram histogram
          pure $
            WorkerResult
              { workerAttempted = attempted
              , workerSuccessful = successful
              , workerErrors = errors
              , workerTimeouts = timeoutsSeen
              , workerHistogram = frozen
              }
        else do
          submissions <- submitBatch nextIndex
          results <- mapM awaitSubmission submissions
          let attempted' = attempted + length results
              successful' = successful + countSuccessful results
              errors' = errors + countErrors results
              timeouts' = timeoutsSeen + countTimeouts results
          loop histogram deadlineNs (nextIndex + benchBatchSize options)
            attempted' successful' errors' timeouts'
      where
        submitBatch baseIndex =
          forM [0 .. benchBatchSize options - 1] $ \offset -> do
            let request = requestPlan options (baseIndex + offset)
            startedNs <- getMonotonicTimeNSec
            try (runtimeSubmitAsync runtime request) >>= \case
              Left (_ :: SomeException) -> pure SubmissionFailed
              Right slot -> pure (Submitted startedNs request slot)

        awaitSubmission SubmissionFailed = pure OutcomeError
        awaitSubmission (Submitted startedNs request slot) = do
          outcome <- try $
            timeout (benchTimeoutMs options * 1000) $
              runtimeWait runtime slot
          finishedNs <- getMonotonicTimeNSec
          recordLatency histogram (nanosToMicros (finishedNs - startedNs))
          pure $
            case outcome of
              Left (_ :: SomeException) -> OutcomeError
              Right Nothing -> OutcomeTimeout
              Right (Just response)
                | responseMatches (requestExpected request) response ->
                    OutcomeSuccess
                | otherwise ->
                    OutcomeError

data Outcome = OutcomeSuccess | OutcomeError | OutcomeTimeout
  deriving (Eq)

countSuccessful, countErrors, countTimeouts :: [Outcome] -> Int
countSuccessful = length . filter (== OutcomeSuccess)
countErrors = length . filter (== OutcomeError)
countTimeouts = length . filter (== OutcomeTimeout)

mergeWorkerResults :: [WorkerResult] -> WorkerResult
mergeWorkerResults [] =
  WorkerResult 0 0 0 0 (VU.replicate histogramBucketCount 0)
mergeWorkerResults (firstResult:rest) =
  foldl merge firstResult rest
  where
    merge left right =
      WorkerResult
        { workerAttempted = workerAttempted left + workerAttempted right
        , workerSuccessful = workerSuccessful left + workerSuccessful right
        , workerErrors = workerErrors left + workerErrors right
        , workerTimeouts = workerTimeouts left + workerTimeouts right
        , workerHistogram = VU.zipWith (+) (workerHistogram left) (workerHistogram right)
        }

requestPlan :: BenchOptions -> Int -> RequestPlan
requestPlan options index =
  case benchOperation options of
    OperationSet ->
      let key = benchmarkKey (benchKeySize options) "bench:set:" index
          value = benchmarkValue (benchPayloadSize options) index
      in RequestPlan key (encodeSetBuilder key value) (ExpectSimpleString "OK")
    OperationGet ->
      let lookupIndex = index `mod` prepopulateItemCount options
          key = benchmarkKey (benchKeySize options) "bench:get:" lookupIndex
          value = benchmarkValue (benchPayloadSize options) lookupIndex
      in RequestPlan key (encodeGetBuilder key) (ExpectBulkString value)
    OperationMixed ->
      if index `mod` 5 == 0
        then let key = benchmarkKey (benchKeySize options) "bench:set:" index
                 value = benchmarkValue (benchPayloadSize options) index
             in RequestPlan key (encodeSetBuilder key value) (ExpectSimpleString "OK")
        else let lookupIndex = index `mod` prepopulateItemCount options
                 key = benchmarkKey (benchKeySize options) "bench:get:" lookupIndex
                 value = benchmarkValue (benchPayloadSize options) lookupIndex
             in RequestPlan key (encodeGetBuilder key) (ExpectBulkString value)
    OperationPing ->
      RequestPlan "bench:ping" pingFrame (ExpectSimpleString "PONG")

responseMatches :: ExpectedResponse -> RespData -> Bool
responseMatches expected response =
  case (expected, response) of
    (ExpectSimpleString wanted, RespSimpleString actual) -> wanted == actual
    (ExpectBulkString wanted, RespBulkString actual)     -> wanted == actual
    _                                                    -> False

benchmarkKey :: Int -> String -> Int -> BS.ByteString
benchmarkKey size prefix index =
  let raw = BS8.pack (prefix ++ show index ++ ":")
  in padToSize size 0x30 raw

benchmarkValue :: Int -> Int -> BS.ByteString
benchmarkValue size index =
  let raw = BS8.pack ("value:" ++ show index ++ ":")
  in padToSize size 0x58 raw

padToSize :: Int -> Word8 -> BS.ByteString -> BS.ByteString
padToSize size fillByte prefix =
  let padding = max 0 (size - BS.length prefix)
  in BS.take size (prefix <> BS.replicate padding fillByte)

prepopulateItemCount :: BenchOptions -> Int
prepopulateItemCount options =
  max 1024 (benchConcurrency options * benchBatchSize options * 8)

pingFrame :: Builder.Builder
pingFrame = Builder.stringUtf8 "*1\r\n$4\r\nPING\r\n"

withStandaloneRuntime :: BenchOptions -> App.RunState -> (Runtime -> IO a) -> IO a
withStandaloneRuntime options runState action
  | benchUseTLS options =
      withStandaloneRuntimeWithConnector
        (authenticatedConnector runState (createTLSConnector runState))
  | otherwise =
      withStandaloneRuntimeWithConnector
        (authenticatedConnector runState (createPlaintextConnector runState))
  where
    address = NodeAddress (benchHost options) (effectivePort options)
    withStandaloneRuntimeWithConnector connector =
      bracket
        (createStandaloneState connector address (benchMuxCount options))
        closeStandaloneState
        (\state -> action (standaloneRuntime state))

withClusterRuntime :: BenchOptions -> App.RunState -> (Runtime -> IO a) -> IO a
withClusterRuntime options runState action
  | benchUseTLS options =
      bracket
        (createClusterClientFromStateWithMuxCount runState (benchMuxCount options) (createTLSConnector runState))
        closeClusterClient
        (action . clusterRuntime options)
  | otherwise =
      bracket
        (createClusterClientFromStateWithMuxCount runState (benchMuxCount options) (createPlaintextConnector runState))
        closeClusterClient
        (action . clusterRuntime options)

withSlowServer :: BenchOptions -> (Int -> IO a) -> IO a
withSlowServer options action =
  bracket (startSlowServer options) stopSlowServer (action . slowServerPort)

authenticatedConnector :: (Client client) => App.RunState -> Connector client -> Connector client
authenticatedConnector runState connector address = do
  connection <- connector address
  when (not $ null $ App.password runState) $ do
    let clientState = ClientState connection BS.empty
    _ <- State.evalStateT
      (runRedisCommandClient $
        App.authenticate (App.username runState) (App.password runState))
      clientState
    pure ()
  pure connection

data StandaloneState = StandaloneState
  { standaloneSlotPool :: !SlotPool
  , standaloneMuxes    :: !(V.Vector Multiplexer)
  , standaloneCounter  :: !(IORef Int)
  }

createStandaloneState
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> Int
  -> IO StandaloneState
createStandaloneState connector address muxCount = do
  slotPool <- createSlotPool 256
  muxCounter <- newIORef 0
  muxes <- bracketOnError
    (mapM (\_ -> createMultiplexerFromConnector connector address) [1 .. max 1 muxCount])
    (mapM_ destroyMultiplexer)
    (pure . V.fromList)
  pure StandaloneState
    { standaloneSlotPool = slotPool
    , standaloneMuxes = muxes
    , standaloneCounter = muxCounter
    }

closeStandaloneState :: StandaloneState -> IO ()
closeStandaloneState state =
  mapM_ destroyMultiplexer (V.toList $ standaloneMuxes state)

standaloneRuntime :: StandaloneState -> Runtime
standaloneRuntime state =
  Runtime
    { runtimeSubmitAsync = \request -> do
        mux <- nextStandaloneMux state
        submitCommandAsync (standaloneSlotPool state) mux (requestFrame request)
    , runtimeWait = waitSlot (standaloneSlotPool state)
    , runtimeSnapshotStats =
        mapM readMultiplexerStats (V.toList $ standaloneMuxes state)
    , runtimePrepopulate = \pairs ->
        forM_ pairs $ \(key, value) -> do
          mux <- nextStandaloneMux state
          slot <- submitCommandAsync (standaloneSlotPool state) mux (encodeSetBuilder key value)
          _ <- waitSlot (standaloneSlotPool state) slot
          pure ()
    }

nextStandaloneMux :: StandaloneState -> IO Multiplexer
nextStandaloneMux state
  | V.length (standaloneMuxes state) == 1 =
      pure (V.head $ standaloneMuxes state)
  | otherwise = do
      index <- atomicModifyIORef' (standaloneCounter state) (\current -> (current + 1, current))
      pure $
        standaloneMuxes state V.! (index `mod` V.length (standaloneMuxes state))

clusterRuntime :: forall client. (Client client) => BenchOptions -> ClusterClient client -> Runtime
clusterRuntime options client =
  Runtime
    { runtimeSubmitAsync = \request -> do
        topology <- readTVarIO (clusterTopology client)
        let slotId = calculateSlot (requestKey request)
        case findNodeAddressForSlot topology slotId of
          Nothing ->
            fail ("No cluster node found for slot " ++ show slotId)
          Just nodeAddress ->
            submitToNodeAsync (clusterMultiplexPool client) (normalizeNodeAddress nodeAddress) (requestFrame request)
    , runtimeWait = waitSlotResult (clusterMultiplexPool client)
    , runtimeSnapshotStats =
        getMultiplexPoolMuxStats (clusterMultiplexPool client)
    , runtimePrepopulate = \pairs -> do
        topology <- readTVarIO (clusterTopology client)
        let masters =
              [ node
              | node <- Map.elems (topologyNodes topology)
              , nodeRole node == Master
              ]
        when (null masters) $
          fail "No cluster masters were available for benchmark prepopulation."
        forM_ pairs $ \(key, value) -> do
          let slotId = calculateSlot key
          case findNodeAddressForSlot topology slotId of
            Nothing ->
              fail ("No cluster node found for slot " ++ show slotId)
            Just nodeAddress -> do
              slot <- submitToNodeAsync (clusterMultiplexPool client) (normalizeNodeAddress nodeAddress) (encodeSetBuilder key value)
              _ <- waitSlotResult (clusterMultiplexPool client) slot
              pure ()
    }
  where
    normalizeNodeAddress nodeAddress
      | benchHost options `elem` ["127.0.0.1", "localhost"]
      , nodeHost nodeAddress /= benchHost options =
          nodeAddress {nodeHost = benchHost options}
      | otherwise =
          nodeAddress

startPressureSampler :: Runtime -> IO PressureSampler
startPressureSampler runtime = do
  stopRef <- newIORef False
  queueRef <- newIORef 0
  flightRef <- newIORef 0
  tid <- forkIO $ do
    let loop = do
          stop <- readIORef stopRef
          unless stop $ do
            sample <- aggregateCurrentPressure <$> runtimeSnapshotStats runtime
            modifyIORef' queueRef (max $ currentQueuedCommands sample)
            modifyIORef' flightRef (max $ currentInFlight sample)
            threadDelay 5000
            loop
    loop
  pure $
    PressureSampler
      { samplerStopRef = stopRef
      , samplerQueueHighRef = queueRef
      , samplerFlightHighRef = flightRef
      , samplerThreadId = tid
      }

stopPressureSampler :: PressureSampler -> IO PressureHighWater
stopPressureSampler sampler = do
  writeIORef (samplerStopRef sampler) True
  threadDelay 10000
  queuePeak <- readIORef (samplerQueueHighRef sampler)
  inFlightPeak <- readIORef (samplerFlightHighRef sampler)
  pure $
    PressureHighWater
      { queueHighWater = queuePeak
      , inFlightHighWater = inFlightPeak
      }

aggregateCurrentPressure :: [MultiplexerStats] -> BackpressureSample
aggregateCurrentPressure stats =
  BackpressureSample
    { currentQueuedCommands = sum (map statsCurrentQueuedCommands stats)
    , currentInFlight = sum (map statsCurrentInFlight stats)
    }

startSlowServer :: BenchOptions -> IO SlowServer
startSlowServer options = do
  addressInfo <- loopbackAddressInfo
  listenSocket <- socket AF_INET Stream defaultProtocol
  setSocketOption listenSocket ReuseAddr 1
  bind listenSocket (addrAddress addressInfo)
  listen listenSocket 16
  port <- socketPort listenSocket
  requestCounter <- newIORef 0
  acceptThread <- forkIO $ acceptLoop listenSocket requestCounter
  pure $
    SlowServer
      { slowServerSocket = listenSocket
      , slowServerThread = acceptThread
      , slowServerPort = port
      }
  where
    acceptLoop listenSocket requestCounter = do
      (clientSocket, _) <- accept listenSocket
      _ <- forkIO $
        let go pending = do
              chunk <- NSB.recv clientSocket 4096
              if BS.null chunk
                then pure ()
                else do
                  let (requests, remainder) = drainRespMessages (pending <> chunk)
                  mapM_ (respond clientSocket requestCounter) requests
                  go remainder
        in go BS.empty `finally` close clientSocket
      acceptLoop listenSocket requestCounter

    respond clientSocket requestCounter _ = do
      requestIndex <- atomicModifyIORef' requestCounter (\current -> let next = current + 1 in (next, next))
      case benchStallAfterRequests options of
        Just stallAfter | requestIndex > stallAfter -> pure ()
        _ -> do
          threadDelay (benchResponseDelayMs options * 1000)
          NSB.sendAll clientSocket "+PONG\r\n"

stopSlowServer :: SlowServer -> IO ()
stopSlowServer server = do
  killThread (slowServerThread server)
  close (slowServerSocket server)

loopbackAddressInfo :: IO AddrInfo
loopbackAddressInfo = do
  infos <- getAddrInfo
    (Just defaultHints {addrFlags = [AI_PASSIVE], addrFamily = AF_INET, addrSocketType = Stream})
    (Just "127.0.0.1")
    (Just "0")
  case infos of
    info : _ -> pure info
    []       -> fail "Unable to allocate loopback listen socket for slow-server benchmark."

socketPort :: Socket -> IO Int
socketPort sock =
  getSocketName sock >>= \case
    SockAddrInet portNumber _      -> pure (fromIntegral portNumber)
    SockAddrInet6 portNumber _ _ _ -> pure (fromIntegral portNumber)
    otherAddress ->
      fail ("Unsupported socket address for slow benchmark server: " ++ show otherAddress)

drainRespMessages :: BS.ByteString -> ([RespData], BS.ByteString)
drainRespMessages input = go [] input
  where
    go acc bytes =
      case AP.parse parseRespData bytes of
        AP.Done remainder value -> go (value : acc) remainder
        AP.Partial _            -> (reverse acc, bytes)
        AP.Fail _ _ message     -> error ("Slow benchmark server received invalid RESP: " ++ message)

captureEnvironment :: IO EnvironmentInfo
captureEnvironment = do
  capturedAt <- getCurrentTime
  hostname <- lookupEnv "HOSTNAME"
  capabilities <- getNumCapabilities
  rtsFlags <- getRTSFlags
  pure $
    EnvironmentInfo
      { environmentCapturedAtUtc = iso8601Show capturedAt
      , environmentHostname = hostname
      , environmentOs = os
      , environmentArch = arch
      , environmentCompiler = compilerName
      , environmentCompilerVersion = showVersion compilerVersion
      , environmentCapabilities = capabilities
      , environmentRtsStatsEnabled = True
      , environmentRtsFlags = rtsFlagsJson rtsFlags
      }

rtsFlagsJson :: RTSFlags -> Aeson.Value
rtsFlagsJson RTSFlags {gcFlags, parFlags} =
  object
    [ "capabilities" .= nCapabilities parFlags
    , "generations" .= generations gcFlags
    , "max_heap_size_mb" .= maxHeapSize gcFlags
    , "heap_size_suggestion_mb" .= heapSizeSuggestion gcFlags
    , "min_allocation_area_kb" .= minAllocAreaSize gcFlags
    , "old_generation_factor" .= oldGenFactor gcFlags
    ]

toRunState :: BenchOptions -> App.RunState
toRunState options =
  App.defaultRunState
    { App.host = benchHost options
    , App.port = Just (effectivePort options)
    , App.username = benchUsername options
    , App.useTLS = benchUseTLS options
    , App.allowInsecurePlaintextAuth = benchAllowInsecureAuth options
    , App.keySize = benchKeySize options
    , App.valueSize = benchPayloadSize options
    , App.benchDuration = benchDurationSeconds options
    , App.muxCount = benchMuxCount options
    }

effectivePort :: BenchOptions -> Int
effectivePort options =
  fromMaybe
    (if benchUseTLS options then 6380 else 6379)
    (benchPort options)

gcCpuPercent :: RTSStats -> RTSStats -> Double
gcCpuPercent before after
  | totalCpu <= 0 = 0
  | otherwise = gcCpu / totalCpu * 100
  where
    totalCpu = fromIntegral (cpu_ns after - cpu_ns before) :: Double
    gcCpu = fromIntegral (gc_cpu_ns after - gc_cpu_ns before) :: Double

nanosToSeconds :: Word64 -> Double
nanosToSeconds nanos = fromIntegral nanos / 1.0e9

secondsToNanos :: Int -> Word64
secondsToNanos seconds = fromIntegral seconds * 1000000000

nanosToMicros :: Word64 -> Int
nanosToMicros nanos = fromIntegral (nanos `div` 1000)

latencyBucketUpperBounds :: VU.Vector Int
latencyBucketUpperBounds =
  VU.fromList $
    [50,100 .. 5000]
      ++ [5200,5400 .. 20000]
      ++ [21000,22000 .. 100000]
      ++ [105000,110000 .. 500000]
      ++ [550000,600000 .. 5000000]

histogramBucketCount :: Int
histogramBucketCount = VU.length latencyBucketUpperBounds + 1

newtype LatencyHistogram = LatencyHistogram { unLatencyHistogram :: VUM.IOVector Int }

newHistogram :: IO LatencyHistogram
newHistogram =
  LatencyHistogram <$> VUM.replicate histogramBucketCount 0

recordLatency :: LatencyHistogram -> Int -> IO ()
recordLatency (LatencyHistogram histogram) latencyMicros =
  VUM.modify histogram (+ 1) (latencyBucketIndex latencyMicros)

freezeHistogram :: LatencyHistogram -> IO (VU.Vector Int)
freezeHistogram = VU.freeze . unLatencyHistogram

latencyBucketIndex :: Int -> Int
latencyBucketIndex value = go 0 (VU.length latencyBucketUpperBounds - 1)
  where
    go low high
      | low > high = low
      | otherwise =
          let middle = (low + high) `div` 2
              bound = latencyBucketUpperBounds VU.! middle
          in if value <= bound
               then go low (middle - 1)
               else go (middle + 1) high

histogramPercentiles :: VU.Vector Int -> Aeson.Value
histogramPercentiles histogram =
  let total = max 1 (VU.sum histogram)
  in object
      [ "p50" .= percentile 0.50 total histogram
      , "p95" .= percentile 0.95 total histogram
      , "p99" .= percentile 0.99 total histogram
      , "p999" .= percentile 0.999 total histogram
      ]

percentile :: Double -> Int -> VU.Vector Int -> Int
percentile pct total histogram =
  go 0 0
  where
    target = ceiling (pct * fromIntegral total)
    overflowBound =
      fromMaybe 5000000 (latencyBucketUpperBounds VU.!? (VU.length latencyBucketUpperBounds - 1))
    go bucketIndex seen
      | bucketIndex >= VU.length histogram = overflowBound
      | seen' >= target =
          if bucketIndex >= VU.length latencyBucketUpperBounds
            then overflowBound
            else latencyBucketUpperBounds VU.! bucketIndex
      | otherwise = go (bucketIndex + 1) seen'
      where
        seen' = seen + histogram VU.! bucketIndex

parseArgs :: [String] -> IO BenchOptions
parseArgs args =
  case getOpt Permute optionParsers args of
    (updates, [], []) -> foldl (>>=) (pure defaultBenchOptions) updates
    (_, _, errors)    -> ioError $ userError (concat errors ++ usageText)

optionParsers :: [OptDescr (BenchOptions -> IO BenchOptions)]
optionParsers =
  [ Option [] ["scenario"] (ReqArg setScenario "standalone|cluster|slow-server") "Scenario"
  , Option ['h'] ["host"] (ReqArg (\value options -> pure options {benchHost = value}) "HOST") "Redis host"
  , Option ['p'] ["port"] (ReqArg (\value options -> do
      portValue <- readPositive "Port" value
      pure options {benchPort = Just portValue}) "PORT") "Redis port"
  , Option ['t'] ["tls"] (NoArg (\options -> pure options {benchUseTLS = True})) "Use TLS"
  , Option ['u'] ["username"] (ReqArg (\value options -> pure options {benchUsername = value}) "USERNAME") "ACL username"
  , Option [] ["allow-insecure-plaintext-auth"] (NoArg (\options -> pure options {benchAllowInsecureAuth = True})) "Allow plaintext auth"
  , Option [] ["duration"] (ReqArg (\value options -> do
      durationSeconds <- readPositive "Duration" value
      pure options {benchDurationSeconds = durationSeconds}) "SECONDS") "Measured duration"
  , Option [] ["warmup"] (ReqArg (\value options -> do
      warmupSeconds <- readNonNegative "Warmup" value
      pure options {benchWarmupSeconds = warmupSeconds}) "SECONDS") "Warmup duration"
  , Option [] ["concurrency"] (ReqArg (\value options -> do
      concurrency <- readPositive "Concurrency" value
      pure options {benchConcurrency = concurrency}) "COUNT") "Worker count"
  , Option [] ["batch-size"] (ReqArg (\value options -> do
      batchSize <- readPositive "Batch size" value
      pure options {benchBatchSize = batchSize}) "COUNT") "Async batch size"
  , Option [] ["mux-count"] (ReqArg (\value options -> do
      muxCount <- readPositive "Mux count" value
      pure options {benchMuxCount = muxCount}) "COUNT") "Muxes per endpoint"
  , Option [] ["key-size"] (ReqArg (\value options -> do
      keySize <- readPositive "Key size" value
      pure options {benchKeySize = keySize}) "BYTES") "Key size"
  , Option [] ["payload-size"] (ReqArg (\value options -> do
      payloadSize <- readPositive "Payload size" value
      pure options {benchPayloadSize = payloadSize}) "BYTES") "Value payload size"
  , Option [] ["operation"] (ReqArg setOperation "set|get|mixed|ping") "Operation mix"
  , Option [] ["timeout-ms"] (ReqArg (\value options -> do
      timeoutMs <- readPositive "Timeout" value
      pure options {benchTimeoutMs = timeoutMs}) "MILLISECONDS") "Per-operation timeout"
  , Option [] ["output"] (ReqArg (\value options -> pure options {benchOutputPath = Just value}) "PATH") "Write JSON result to PATH"
  , Option [] ["response-delay-ms"] (ReqArg (\value options -> do
      delayMs <- readPositive "Response delay" value
      pure options {benchResponseDelayMs = delayMs}) "MILLISECONDS") "Slow-server response delay"
  , Option [] ["stall-after-requests"] (ReqArg (\value options -> do
      requestCount <- readPositive "Stall after requests" value
      pure options {benchStallAfterRequests = Just requestCount}) "COUNT") "Slow-server stall threshold"
  ]

usageText :: String
usageText =
  unlines
    [ "Usage: redis-client-benchmark [OPTIONS]"
    , ""
    , "Required RTS flags: +RTS -T -RTS"
    ]

setScenario :: String -> BenchOptions -> IO BenchOptions
setScenario value options =
  case value of
    "standalone" -> pure options {benchScenario = ScenarioStandalone}
    "cluster" -> pure options {benchScenario = ScenarioCluster}
    "slow-server" -> pure options {benchScenario = ScenarioSlowServer}
    _ -> ioError $ userError "Scenario must be standalone, cluster, or slow-server"

setOperation :: String -> BenchOptions -> IO BenchOptions
setOperation value options =
  case value of
    "set"   -> pure options {benchOperation = OperationSet}
    "get"   -> pure options {benchOperation = OperationGet}
    "mixed" -> pure options {benchOperation = OperationMixed}
    "ping"  -> pure options {benchOperation = OperationPing}
    _       -> ioError $ userError "Operation must be set, get, mixed, or ping"

readPositive :: String -> String -> IO Int
readPositive label raw =
  case readMaybe raw of
    Just value | value > 0 -> pure value
    _ -> ioError $ userError (label ++ " must be a positive integer")

readNonNegative :: String -> String -> IO Int
readNonNegative label raw =
  case readMaybe raw of
    Just value | value >= 0 -> pure value
    _ -> ioError $ userError (label ++ " must be a non-negative integer")
