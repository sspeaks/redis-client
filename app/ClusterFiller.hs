{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterFiller
  ( fillClusterWithData
  ) where

import           Client                  (Client (..), ConnectionStatus (..))
import           Cluster                 (ClusterNode (..),
                                          ClusterTopology (..),
                                          NodeAddress (..), NodeRole (..),
                                          SlotRange (..))
import           ClusterCommandClient    (ClusterClient (..))
import           ClusterSlotMapping      (slotMappings)
import           Connector               (Connector)
import           Control.Concurrent      (MVar, forkIO, newEmptyMVar, putMVar,
                                          takeMVar, threadDelay)
import           Control.Concurrent.STM  (readTVarIO)
import           Control.Exception       (SomeException, catch)
import           Control.Monad           (when)
import qualified Control.Monad.State     as State
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LBS
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Vector             as V
import qualified Data.Vector.Unboxed     as VU
import           Data.Word               (Word16, Word64)
import           Filler                  (sendChunkedFill)
import           Data.List               (find)
import           FillHelpers             (generateBytes,
                                          generateBytesWithHashTag, nextLCG,
                                          threadSeedSpacing)
import           RedisCommandClient      (ClientReplyValues (..),
                                          ClientState (..), RedisCommands (..),
                                          runRedisCommandClient)
import           System.Timeout          (timeout)
import           Text.Printf             (printf)



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
fillClusterWithData clusterClient connector totalGB threadsPerNode baseSeed keySize valueSize pipelineBatchSize = do
  -- Get cluster topology to find master nodes
  topology <- readTVarIO (clusterTopology clusterClient)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
      numMasters = length masterNodes

  when (numMasters == 0) $ do
    putStrLn "Error: No master nodes found in cluster"
    return ()

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

  -- Execute jobs in parallel
  mvars <- mapM (executeJob clusterClient connector slotRanges baseSeed keySize valueSize pipelineBatchSize) jobs
  mapM_ takeMVar mvars

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
    calculateSlotRangesPerMaster :: ClusterTopology -> [ClusterNode] -> Map Text [Word16]
    calculateSlotRangesPerMaster _ masters =
      Map.fromList [(nodeId node, expandSlotRanges (nodeSlotsServed node)) | node <- masters]

    -- | Expand a list of SlotRange into individual slot numbers
    expandSlotRanges :: [SlotRange] -> [Word16]
    expandSlotRanges = concatMap (\r -> [slotStart r .. slotEnd r])

-- | Execute a single fill job on a specific node
executeJob ::
  (Client client) =>
  ClusterClient client ->
  Connector client ->
  Map Text [Word16] ->
  Word64 ->
  Int ->                              -- Key size in bytes
  Int ->                              -- Value size in bytes
  Int ->                              -- Pipeline batch size
  (NodeAddress, Int, Int) ->  -- (address, threadIdx, mbToFill)
  IO (MVar ())
executeJob clusterClient connector slotRanges baseSeed keySize valueSize pipelineBatchSize (addr, threadIdx, mbToFill) = do
  -- If this thread has no work, return immediately
  if mbToFill <= 0
    then do
      mvar <- newEmptyMVar
      putMVar mvar ()
      return mvar
    else do
      mvar <- newEmptyMVar
      _ <- forkIO $ do
        -- Wrap the entire thread work in exception handler to ensure mvar is always filled
        catch (do
          -- Suppress per-thread logging to reduce spam with many processes/threads
          -- Only log if something goes wrong

          -- Stagger connection creation to avoid overwhelming TLS handshakes
          -- With many processes/threads hitting the same nodes simultaneously,
          -- we can get "bad record mac" errors if TLS handshakes collide
          threadDelay (threadIdx * 50000)  -- 50ms per thread index

          -- Create a unique connection for this thread using connector directly
          -- This avoids connection pool contention where threads share connections
          conn <- connector addr

          -- Find which slots this node owns
          topology <- readTVarIO (clusterTopology clusterClient)
          let masters = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
              maybeNode = findNodeByAddress masters addr

          case maybeNode of
            Nothing -> do
              printf "Warning: Could not find node for address %s:%d\n"
                     (nodeHost addr) (nodePort addr)
            Just node -> do
              let nId = nodeId node
                  slots = Map.findWithDefault [] nId slotRanges

              when (null slots) $ do
                printf "Warning: Node %s has no assigned slots\n" (T.unpack nId)

              -- Fill data for this node using its slots
              fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize
          ) (\e -> do
            -- If any exception occurs, log it and continue
            printf "Error in thread %d for node %s:%d: %s\n"
                   threadIdx (nodeHost addr) (nodePort addr) (show (e :: SomeException))
          )

        -- Always signal completion, even if there was an error
        putMVar mvar ()

      return mvar
  where
    -- | Find a cluster node by its address
    -- Returns the first node matching the address, or Nothing if not found
    findNodeByAddress :: [ClusterNode] -> NodeAddress -> Maybe ClusterNode
    findNodeByAddress nodes nodeAddr = find (\n -> nodeAddress n == nodeAddr) nodes

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
fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize valueSize pipelineBatchSize = do
  when (null slots) $ return ()

  -- Convert slots list to Vector for O(1) access in the hot loop
  let !slotsVec = VU.fromList slots

  -- Deterministic seed for this thread
  let threadSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
      genChunk batchSize seed = generateClusterChunk slotsVec batchSize keySize valueSize seed

  -- Wrap in exception handler and timeout
  catch (do
    let clientState = ClientState conn BS.empty
        fillAction = do
          _ <- clientReply OFF
          sendChunkedFill genChunk mbToFill pipelineBatchSize (keySize + valueSize) threadSeed
          _ <- clientReply ON
          _ <- dbsize
          return ()

    result <- timeout (600 * 1000000) $ State.evalStateT (runRedisCommandClient fillAction) clientState
    case result of
      Just _ -> return ()
      Nothing -> printf "Thread %d for slots timed out after 10 minutes\n" threadIdx
    ) (\e -> do
      printf "Thread %d failed with error: %s\n" threadIdx (show (e :: SomeException))
    )
  return ()

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
