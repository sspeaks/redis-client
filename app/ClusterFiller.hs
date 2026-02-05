{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module ClusterFiller
  ( fillClusterWithData
  ) where

import           ClusterSlotMapping      (slotMappings)
import           Client                  (Client (..), ConnectionStatus (..))
import           Cluster                 (ClusterNode (..),
                                          ClusterTopology (..),
                                          NodeAddress (..), NodeRole (..),
                                          SlotRange (..))
import           ClusterCommandClient    (ClusterClient (..))
import           Control.Concurrent      (MVar, forkIO, newEmptyMVar, putMVar,
                                          takeMVar)
import           Control.Concurrent.STM  (readTVarIO)
import           Control.Exception       (SomeException, catch)
import           Control.Monad           (when)
import qualified Control.Monad.State     as State
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LB
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Vector             as V
import qualified Data.Vector.Unboxed     as VU
import           Data.Word               (Word16, Word64)
import           Filler                  (lookupChunkKilos)
import           FillHelpers             (generateBytes, generateBytesWithHashTag, randomNoise)
import           RedisCommandClient      (ClientReplyValues (..),
                                          ClientState (..), RedisCommands (..),
                                          runRedisCommandClient)
import           System.Timeout          (timeout)
import           Text.Printf             (printf)



-- | Fill cluster with data, distributing work across master nodes
fillClusterWithData ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  Int ->              -- Total GB to fill
  Int ->              -- Threads per node
  Word64 ->           -- Base seed for randomness
  Int ->              -- Key size in bytes
  IO ()
fillClusterWithData clusterClient connector totalGB threadsPerNode baseSeed keySize = do
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

  printf "Distributing %dGB (%dMB) across %d master nodes using %d threads per node (key size: %d bytes)\n"
         totalGB totalMB numMasters threadsPerNode keySize

  -- Create jobs: (nodeAddress, threadIdx, mbToFill)
  let jobs = concatMap (createJobsForNode baseMBPerNode mbRemainder threadsPerNode)
                       (zip [0..] masterNodes)

  printf "Total jobs: %d (%d nodes * %d threads)\n"
         (length jobs) numMasters threadsPerNode

  -- Execute jobs in parallel
  mvars <- mapM (executeJob clusterClient connector slotRanges baseSeed keySize) jobs
  mapM_ takeMVar mvars

  putStrLn "Cluster fill complete!"
  where
    -- | Create fill jobs for a single master node
    -- Distributes the node's workload across multiple threads
    -- Uses MB instead of key counts to match standalone behavior
    createJobsForNode :: Int -> Int -> Int -> (Int, ClusterNode) -> [(NodeAddress, Int, Int)]
    createJobsForNode baseMB remainder threadsPerNode (nodeIdx, node) =
      let mbForThisNode = baseMB + (if nodeIdx < remainder then 1 else 0)
          mbPerThread = mbForThisNode `div` threadsPerNode
          threadRemainder = mbForThisNode `mod` threadsPerNode
      in [(nodeAddress node,
           threadIdx,
           mbPerThread + (if threadIdx < threadRemainder then 1 else 0))
         | threadIdx <- [0..threadsPerNode - 1]]

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
  (NodeAddress -> IO (client 'Connected)) ->
  Map Text [Word16] ->
  Word64 ->
  Int ->                              -- Key size in bytes
  (NodeAddress, Int, Int) ->  -- (address, threadIdx, mbToFill)
  IO (MVar ())
executeJob clusterClient connector slotRanges baseSeed keySize (addr, threadIdx, mbToFill) = do
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
          printf "Thread %d filling %dMB on node %s:%d\n"
                 threadIdx mbToFill (nodeHost addr) (nodePort addr)

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
              fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize
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
    findNodeByAddress nodes nodeAddr =
      case [n | n <- nodes, nodeAddress n == nodeAddr] of
        (n:_) -> Just n
        []    -> Nothing

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
  IO ()
fillNodeWithData conn slots mbToFill baseSeed threadIdx keySize = do
  when (null slots) $ return ()

  -- Convert slots list to Vector for O(1) access in the hot loop
  let !slotsVec = VU.fromList slots

  -- Deterministic seed for this thread
  let threadSeed = baseSeed + (fromIntegral threadIdx * 1000000000)

  chunkKilos <- lookupChunkKilos

  -- Wrap in exception handler and timeout
  catch (do
    -- Client state for running commands
    let clientState = ClientState conn BS.empty
        fillAction = do
          -- Turn off client replies for maximum throughput (fire-and-forget)
          _ <- clientReply OFF

          -- Calculate total commands needed based on actual data size
          -- Each command stores: keySize bytes (key) + 512 bytes (value)
          let bytesPerCommand = keySize + 512
              totalBytesNeeded = mbToFill * 1024 * 1024  -- Convert MB to bytes
              totalCommandsNeeded = (totalBytesNeeded + bytesPerCommand - 1) `div` bytesPerCommand  -- Ceiling division
              
              -- Calculate chunks and remainder for exact distribution
              fullChunks = totalCommandsNeeded `div` chunkKilos
              remainderCommands = totalCommandsNeeded `mod` chunkKilos

          -- Generate and send all full chunks
          mapM_ (\chunkIdx -> do
              ClientState client _ <- State.get
              let cmd = generateClusterChunk slotsVec chunkKilos keySize (threadSeed + fromIntegral chunkIdx)
              send client cmd
            ) [0..fullChunks - 1]
          
          -- Send the remainder chunk if there is one
          when (remainderCommands > 0) $ do
              ClientState client _ <- State.get
              let cmd = generateClusterChunk slotsVec remainderCommands keySize (threadSeed + fromIntegral fullChunks)
              send client cmd

          -- Turn replies back on
          _ <- clientReply ON
          _ <- dbsize
          return ()

    -- Run the fill action with a 10 minute timeout (600 seconds)
    -- This is generous but prevents indefinite hangs
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
  Word64 ->
  LB.ByteString
generateClusterChunk slots chunkKilos keySize seed =
  Builder.toLazyByteString $! go chunkKilos seed
  where
    !numSlots = VU.length slots

    -- Pre-computed RESP protocol constants with dynamic key size
    setPrefix :: Builder.Builder
    setPrefix = Builder.stringUtf8 "*3\r\n$3\r\nSET\r\n$" <> Builder.intDec keySize <> Builder.stringUtf8 "\r\n"
    {-# INLINE setPrefix #-}

    valuePrefix :: Builder.Builder
    valuePrefix = Builder.stringUtf8 "\r\n$512\r\n"
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
          !valSeed = s * 6364136223846793005 + 1442695040888963407
          !nextSeed = valSeed * 6364136223846793005 + 1442695040888963407

          !keyData = generateBytesWithHashTag keySize hashTag keySeed
          !valData = generate512Bytes valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}

    -- | Generate 512 bytes of data for values
    generate512Bytes :: Word64 -> Builder.Builder
    generate512Bytes !s =
      let !scrambled = s * 6364136223846793005 + 1442695040888963407
          !offset = fromIntegral (scrambled `rem` (128 * 1024 * 1024 - 512))
          !chunk = BS.take 504 (BS.drop offset randomNoise)
      in Builder.word64LE s <> Builder.byteString chunk
    {-# INLINE generate512Bytes #-}
