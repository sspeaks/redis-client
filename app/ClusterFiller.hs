{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module ClusterFiller
  ( fillClusterWithData
  , SlotMapping
  , loadSlotMappings
  ) where

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
import           Data.Bits               (shiftR)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8   as BSC
import qualified Data.ByteString.Lazy    as LB
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text               as T
import           Data.Vector             (Vector)
import qualified Data.Vector             as V
import qualified Data.Vector.Unboxed     as VU
import           Data.Word               (Word16, Word64, Word8)
import           Filler                  (lookupChunkKilos)
import           RedisCommandClient      (ClientReplyValues (..),
                                          ClientState (..), RedisCommands (..),
                                          runRedisCommandClient)
import           System.IO               (IOMode (..), hGetContents, openFile)
import           System.Timeout          (timeout)
import           Text.Printf             (printf)

-- | Mapping from slot number (0-16383) to hash tag that routes to that slot
-- Uses Vector for O(1) lookup instead of Map's O(log n)
type SlotMapping = Vector BS.ByteString

-- 128MB of pre-computed random noise for key/value generation
-- Same pattern as Filler.hs
randomNoise :: BS.ByteString
randomNoise = fst $ BS.unfoldrN (128 * 1024 * 1024) step 0
  where
    step :: Word64 -> Maybe (Word8, Word64)
    step !s = Just (fromIntegral (s `shiftR` 56), s * 6364136223846793005 + 1442695040888963407)
{-# NOINLINE randomNoise #-}

-- | Load slot-to-hashtag mappings from file
-- File format: "slotNumber hashTag" per line
-- Returns a Vector of 16384 elements for O(1) slot lookup
loadSlotMappings :: FilePath -> IO SlotMapping
loadSlotMappings filepath = do
  content <- openFile filepath ReadMode >>= hGetContents
  let entries = map parseLine $ lines content
      validEntries = [(slot, tag) | Just (slot, tag) <- entries]
      -- Build a Map first, then convert to Vector for O(1) access
      entryMap = Map.fromList validEntries
  -- Create a vector of 16384 slots, empty ByteString for missing entries
  return $ V.generate 16384 (\i -> Map.findWithDefault BS.empty (fromIntegral i) entryMap)
  where
    parseLine :: String -> Maybe (Word16, BS.ByteString)
    parseLine line =
      case words line of
        [slotStr, tag] -> case reads slotStr of
          [(slot, "")] -> Just (slot, BSC.pack tag)
          _            -> Nothing
        _ -> Nothing

-- | Fill cluster with data, distributing work across master nodes
fillClusterWithData ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  SlotMapping ->
  Int ->              -- Total GB to fill
  Int ->              -- Threads per node
  Word64 ->           -- Base seed for randomness
  IO ()
fillClusterWithData clusterClient connector slotMappings totalGB threadsPerNode baseSeed = do
  -- Get cluster topology to find master nodes
  topology <- readTVarIO (clusterTopology clusterClient)
  let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]
      numMasters = length masterNodes

  when (numMasters == 0) $ do
    putStrLn "Error: No master nodes found in cluster"
    return ()

  -- Calculate slot distribution for each master
  let slotRanges = calculateSlotRangesPerMaster topology masterNodes

  -- Calculate MB per node for even distribution
  let totalMB = totalGB * 1024
      baseMBPerNode = totalMB `div` numMasters
      remainder = totalMB `mod` numMasters

  printf "Distributing %dGB across %d master nodes using %d threads per node\n"
         totalGB numMasters threadsPerNode

  -- Create jobs: (nodeAddress, slots, mbToFill, threadIdx)
  let jobs = concatMap (createJobsForNode baseMBPerNode remainder threadsPerNode)
                       (zip [0..] masterNodes)

  printf "Total jobs: %d (%d nodes * %d threads)\n"
         (length jobs) numMasters threadsPerNode

  -- Execute jobs in parallel
  mvars <- mapM (executeJob clusterClient connector slotMappings slotRanges baseSeed) jobs
  mapM_ takeMVar mvars

  putStrLn "Cluster fill complete!"
  where
    -- | Create fill jobs for a single master node
    -- Distributes the node's workload across multiple threads
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
  SlotMapping ->
  Map Text [Word16] ->
  Word64 ->
  (NodeAddress, Int, Int) ->
  IO (MVar ())
executeJob clusterClient connector slotMappings slotRanges baseSeed (addr, threadIdx, mbToFill) = do
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
              fillNodeWithData conn slotMappings slots mbToFill baseSeed threadIdx
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
    findNodeByAddress nodes addr =
      case [n | n <- nodes, nodeAddress n == addr] of
        (n:_) -> Just n
        []    -> Nothing

-- | Fill a specific node with data using its assigned slots
fillNodeWithData ::
  (Client client) =>
  client 'Connected ->
  SlotMapping ->
  [Word16] ->
  Int ->
  Word64 ->
  Int ->
  IO ()
fillNodeWithData conn slotMappings slots mbToFill baseSeed threadIdx = do
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

          -- Calculate chunks needed
          let totalKilos = mbToFill * 1024
              totalChunks = (totalKilos + chunkKilos - 1) `div` chunkKilos

          -- Generate and send data chunks (no replies expected)
          mapM_ (\chunkIdx -> do
              ClientState client _ <- State.get
              let cmd = generateClusterChunk slotMappings slotsVec chunkKilos (threadSeed + fromIntegral chunkIdx)
              send client cmd
            ) [0..totalChunks - 1]

          -- Turn replies back on
          _ <- clientReply ON
          dbsize

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
  SlotMapping ->
  VU.Vector Word16 ->
  Int ->
  Word64 ->
  LB.ByteString
generateClusterChunk slotMappings slots chunkKilos seed =
  Builder.toLazyByteString $! go chunkKilos seed
  where
    !numSlots = VU.length slots

    -- Pre-computed RESP protocol constants - hoisted out of loop
    setPrefix :: Builder.Builder
    setPrefix = Builder.stringUtf8 "*3\r\n$3\r\nSET\r\n$512\r\n"
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

          !keyData = generate512BytesWithHashTag hashTag keySeed
          !valData = generate512Bytes valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}

    -- Generate key with hash tag prefix to ensure proper routing
    -- Empty hash tag means no routing needed, fall back to regular generation
    generate512BytesWithHashTag :: BS.ByteString -> Word64 -> Builder.Builder
    generate512BytesWithHashTag hashTag !seed
      | BS.null hashTag = generate512Bytes seed
      | otherwise =
          let !tagLen = BS.length hashTag
              -- Format: {hashtag}:seed:padding
              -- We need exactly 512 bytes total
              !seedBytes = Builder.word64LE seed  -- 8 bytes
              !prefix = Builder.char8 '{' <> Builder.byteString hashTag <> Builder.stringUtf8 "}:"
              !prefixLen = 2 + tagLen + 1  -- { + tag + }:

              -- Fill remaining bytes with noise
              !totalPrefix = prefixLen + 8  -- prefix + seed
              !paddingNeeded = 512 - totalPrefix

              !scrambled = seed * 6364136223846793005 + 1442695040888963407
              !offset = fromIntegral (scrambled `rem` (128 * 1024 * 1024 - 512))
              !padding = BS.take paddingNeeded (BS.drop offset randomNoise)
          in prefix <> seedBytes <> Builder.byteString padding
    {-# INLINE generate512BytesWithHashTag #-}

    -- | Generate 512 bytes of data (same as in Filler.hs)
    generate512Bytes :: Word64 -> Builder.Builder
    generate512Bytes !s =
      let !scrambled = s * 6364136223846793005 + 1442695040888963407
          !offset = fromIntegral (scrambled `rem` (128 * 1024 * 1024 - 512))
          !chunk = BS.take 504 (BS.drop offset randomNoise)
      in Builder.word64LE s <> Builder.byteString chunk
    {-# INLINE generate512Bytes #-}
