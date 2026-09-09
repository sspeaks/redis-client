{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterFiller
  ( executeClusterFillJob
  , fillClusterWithData
  , withClusterFillClient
  , withClusterFillConnection
  , fillNodeWithDataWithTimeout
  ) where

import           Control.Concurrent                 (threadDelay)
import           Control.Concurrent.STM             (readTVarIO)
import           Control.Exception                  (bracket, throwIO)
import           Control.Monad                      (unless, when)
import qualified Control.Monad.State                as State
import qualified Data.ByteString                    as BS
import qualified Data.ByteString.Builder            as Builder
import           Data.ByteString.Char8              (ByteString)
import qualified Data.ByteString.Lazy               as LBS
import           Data.List                          (find)
import           Data.Map.Strict                    (Map)
import qualified Data.Map.Strict                    as Map
import qualified Data.Vector                        as V
import qualified Data.Vector.Unboxed                as VU
import           Data.Word                          (Word16, Word64)
import           Database.Redis.Client              (Client (..),
                                                     ConnectionStatus (..))
import           Database.Redis.Cluster             (ClusterNode (..),
                                                     ClusterTopology (..),
                                                     NodeAddress (..),
                                                     NodeRole (..),
                                                     SlotRange (..))
import           Database.Redis.Cluster.Client      (ClusterClient (..),
                                                     closeClusterClient)
import           Database.Redis.Cluster.SlotMapping (slotMappings)
import           Database.Redis.Command             (ClientReplyValues (..),
                                                     ClientState (..),
                                                     RedisCommands (..),
                                                     runRedisCommandClient)
import           Database.Redis.Connector           (Connector)
import           Database.Redis.Resp                (RespData)
import           Filler                             (sendChunkedFill)
import           FillHelpers                        (generateBytes,
                                                     generateBytesWithHashTag,
                                                     nextLCG, threadSeedSpacing)
import           StructuredConcurrency              (runConcurrentlyFailFast)
import           System.Timeout                     (timeout)
import           Text.Printf                        (printf)



-- | Fill cluster with data, distributing work across master nodes
fillClusterWithData ::
  (Client client) =>
  ClusterClient client ->
  Connector client ->
  Int ->              -- Total GB to fill
  Int ->              -- Threads per node
  Word64 ->           -- Base seed for randomness
  Int ->              -- Key size in bytes
  Int ->              -- Value size in bytes
  Int ->              -- Pipeline batch size
  IO ()
fillClusterWithData clusterClient _connector totalGB threadsPerNode baseSeed keySize valueSize pipelineBatchSize = do
  -- Get cluster topology to find master nodes
  topology <- readTVarIO (clusterTopology clusterClient)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
      numMasters = length masterNodes

  when (numMasters == 0) $ do
    ioError $ userError "No master nodes found in cluster"

  -- Calculate slot distribution for each master
  let slotRanges = calculateSlotRangesPerMaster topology masterNodes

  -- Work in MB for finer granularity, just like standalone Filler does
  -- This ensures -d flag represents actual data size regardless of key size
  let totalMB = totalGB * 1024
      baseMBPerNode = totalMB `div` numMasters
      mbRemainder = totalMB `mod` numMasters

  -- Only show distribution details if not a child process spawned by multi-process
  printf "Distributing %dGB across %d nodes with %d threads/node\n"
         totalGB numMasters threadsPerNode

  -- Create jobs: (nodeAddress, threadIdx, mbToFill)
  let jobs = concatMap (createJobsForNode baseMBPerNode mbRemainder threadsPerNode)
                       (zip [0..] masterNodes)

  runConcurrentlyFailFast
    [ executeClusterFillJob clusterClient (clusterConnector clusterClient)
        slotRanges baseSeed keySize valueSize pipelineBatchSize job
    | job <- jobs
    ]

  putStrLn "Cluster fill complete!"
  where
    -- | Create fill jobs for a single master node
    -- Distributes the node's workload across multiple threads
    -- Uses MB instead of key counts to match standalone behavior
    createJobsForNode :: Int -> Int -> Int -> (Int, ClusterNode) -> [(NodeAddress, Int, Int)]
    createJobsForNode baseMB remainder tpn (nodeIdx, node) =
      let mbForThisNode = baseMB + (if nodeIdx < remainder then 1 else 0)
          mbPerThread = mbForThisNode `div` tpn
          threadRemainder = mbForThisNode `mod` tpn
      in [(nodeAddress node,
           threadIdx,
           mbPerThread + (if threadIdx < threadRemainder then 1 else 0))
         | threadIdx <- [0..tpn - 1]]

    -- | Calculate which hash slots each master node is responsible for
    -- Returns a map from node ID to list of slot numbers
    calculateSlotRangesPerMaster :: ClusterTopology -> [ClusterNode] -> Map ByteString [Word16]
    calculateSlotRangesPerMaster _ masters =
      Map.fromList [(nodeId node, expandSlotRanges (nodeSlotsServed node)) | node <- masters]

    -- | Expand a list of SlotRange into individual slot numbers
    expandSlotRanges :: [SlotRange] -> [Word16]
    expandSlotRanges = concatMap (\r -> [slotStart r .. slotEnd r])

-- | Execute a single fill job on a specific node
executeClusterFillJob ::
  (Client client) =>
  ClusterClient client ->
  Connector client ->
  Map ByteString [Word16] ->
  Word64 ->
  Int ->                              -- Key size in bytes
  Int ->                              -- Value size in bytes
  Int ->                              -- Pipeline batch size
  (NodeAddress, Int, Int) ->  -- (address, threadIdx, mbToFill)
  IO ()
executeClusterFillJob clusterClient connector slotRanges baseSeed keySize valueSize pipelineBatchSize (addr, threadIdx, mbToFill)
  | mbToFill <= 0 = pure ()
  | otherwise = do
      threadDelay (threadIdx * 50000)
      withClusterFillConnection connector addr $ \conn -> do
        topology <- readTVarIO (clusterTopology clusterClient)
        let masters = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
            maybeNode = findNodeByAddress masters addr

        case maybeNode of
          Nothing ->
            ioError . userError $
              "Cluster fill worker lost its assigned node "
                ++ nodeHost addr ++ ":" ++ show (nodePort addr)
          Just node -> do
            let nId = nodeId node
                slots = Map.findWithDefault [] nId slotRanges
            when (null slots) $
              ioError . userError $
                "Cluster fill worker found no slots for node " ++ show nId
            fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize
  where
    -- | Find a cluster node by its address
    -- Returns the first node matching the address, or Nothing if not found
    findNodeByAddress :: [ClusterNode] -> NodeAddress -> Maybe ClusterNode
    findNodeByAddress nodes nodeAddr = find (\n -> nodeAddress n == nodeAddr) nodes

-- | Scope the parent cluster client, including both backing pools.
withClusterFillClient
  :: (Client client)
  => IO (ClusterClient client)
  -> (ClusterClient client -> IO a)
  -> IO a
withClusterFillClient acquire = bracket acquire closeClusterClient

-- | A fill worker owns its direct transport for the duration of its job.
withClusterFillConnection
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> (client 'Connected -> IO a)
  -> IO a
withClusterFillConnection connector addr = bracket (connector addr) close

-- | Fill a specific node with data using its assigned slots
-- Uses MB for finer-grained allocation, matching standalone mode behavior
fillNodeWithData ::
  (Client client) =>
  client 'Connected ->
  [Word16] ->
  Int ->       -- mbToFill (megabytes to fill)
  Word64 ->
  Int ->
  Int ->       -- Key size in bytes
  Int ->       -- Value size in bytes
  Int ->       -- Pipeline batch size
  IO ()
fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize =
  fillNodeWithDataWithTimeout 600 conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize

-- | The production worker uses a ten-minute deadline.  Keeping the deadline
-- explicit makes the same worker path testable with a short deterministic one.
fillNodeWithDataWithTimeout ::
  (Client client) =>
  Int ->       -- timeout in seconds
  client 'Connected ->
  [Word16] ->
  Int ->       -- mbToFill (megabytes to fill)
  Word64 ->
  Int ->
  Int ->       -- Key size in bytes
  Int ->       -- Value size in bytes
  Int ->       -- Pipeline batch size
  IO ()
fillNodeWithDataWithTimeout timeoutSeconds conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize =
  unless (null slots) $ do
  -- Convert slots list to Vector for O(1) access in the hot loop
    let !slotsVec = VU.fromList slots

  -- Deterministic seed for this thread
    let threadSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
        genChunk batchSize seed = generateClusterChunk slotsVec batchSize keySize valueSize seed

    let clientState = ClientState conn BS.empty
        fillAction = do
          _ <- clientReply OFF
          sendChunkedFill genChunk mbToFill pipelineBatchSize (keySize + valueSize) threadSeed
          _ <- clientReply ON
          (_ :: RespData) <- dbsize
          return ()

    result <- timeout (timeoutSeconds * 1000000) $
      State.evalStateT (runRedisCommandClient fillAction) clientState
    case result of
      Just _  -> pure ()
      Nothing -> throwIO $ userError $
        "Cluster fill worker timed out after " ++ show timeoutSeconds
          ++ " seconds (thread " ++ show threadIdx ++ ")"

-- | Generate a chunk of SET commands using hash tags for proper slot routing
-- Uses Vector for O(1) slot lookup instead of list indexing
generateClusterChunk ::
  VU.Vector Word16 ->
  Int ->
  Int ->      -- Key size in bytes
  Int ->      -- Value size in bytes
  Word64 ->
  LBS.ByteString
generateClusterChunk slots batchSize keySize valueSize seed =
  Builder.toLazyByteString $! go batchSize seed
  where
    !numSlots = VU.length slots

    -- Pre-computed RESP protocol constants with dynamic key size and value size
    setPrefix :: Builder.Builder
    setPrefix = Builder.stringUtf8 "*3\r\n$3\r\nSET\r\n$" <> Builder.intDec keySize <> Builder.stringUtf8 "\r\n"
    {-# INLINE setPrefix #-}

    valuePrefix :: Builder.Builder
    valuePrefix = Builder.stringUtf8 "\r\n$" <> Builder.intDec valueSize <> Builder.stringUtf8 "\r\n"
    {-# INLINE valuePrefix #-}

    commandSuffix :: Builder.Builder
    commandSuffix = Builder.stringUtf8 "\r\n"
    {-# INLINE commandSuffix #-}

    go :: Int -> Word64 -> Builder.Builder
    go 0 _ = mempty
    go n !s =
      let !slotIdx = fromIntegral s `mod` numSlots
          -- O(1) Vector lookup instead of O(n) list indexing
          !slot = slots `VU.unsafeIndex` slotIdx
          -- O(1) Vector lookup instead of O(log n) Map lookup
          !hashTag = slotMappings `V.unsafeIndex` fromIntegral slot

          !keySeed = s
          !valSeed = nextLCG s
          !nextSeed = nextLCG valSeed

          !keyData = generateBytesWithHashTag keySize hashTag keySeed
          !valData = generateBytes valueSize valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}
