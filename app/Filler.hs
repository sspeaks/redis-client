{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import qualified Data.ByteString.Char8 as BSC
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (dbsize, clientReply, set), ClientReplyValues (OFF, ON))
import Resp (RespData (..), Encodable (encode))
import System.Environment (lookupEnv)
import Data.Word (Word64, Word8, Word16)
import Data.Bits (shiftR)
import Text.Read (readMaybe)
import Text.Printf (printf)

-- Simple fast PRNG that directly generates Builder output
gen :: Word64 -> Builder.Builder
gen s = Builder.word64LE s <> gen (s * 1664525 + 1013904223)
{-# INLINE gen #-}

-- 128MB of pre-computed random noise (larger buffer reduces collision probability)
-- Uses unfoldrN to generate directly into a buffer, avoiding the ~5GB overhead 
-- of constructing an intermediate [Word8] list.
randomNoise :: BS.ByteString
randomNoise = fst $ BS.unfoldrN (128 * 1024 * 1024) step 0
  where
    step :: Word64 -> Maybe (Word8, Word64)
    step !s = Just (fromIntegral (s `shiftR` 56), s * 6364136223846793005 + 1442695040888963407)
{-# NOINLINE randomNoise #-}

-- | Forces evaluation of the noise buffer to ensure it is shared and ready.
initRandomNoise :: IO ()
initRandomNoise = do
    let !len = BS.length randomNoise
    printf "Initialized shared random noise buffer: %d MB\n" (len `div` (1024 * 1024))
    
genRandomSet :: Int -> Word64 -> LB.ByteString
genRandomSet chunkKilos seed = Builder.toLazyByteString $! go numCommands seed
  where
    numCommands = chunkKilos
    
    -- Pre-computed RESP protocol prefix for SET commands
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
      let !keySeed = s
          !valSeed = s * 6364136223846793005 + 1442695040888963407
          !nextSeed = valSeed * 6364136223846793005 + 1442695040888963407
          !keyData = generate512Bytes keySeed
          !valData = generate512Bytes valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}
    
    -- Generate exactly 512 bytes efficiently (8 bytes unique seed + 504 bytes noise)
    generate512Bytes :: Word64 -> Builder.Builder
    generate512Bytes !s = 
        let !scrambled = s * 6364136223846793005 + 1442695040888963407
            !offset = fromIntegral (scrambled `rem` (128 * 1024 * 1024 - 512))
            !chunk = BS.take 504 (BS.drop offset randomNoise)
        in Builder.word64LE s <> Builder.byteString chunk
    {-# INLINE generate512Bytes #-}

defaultChunkKilos :: Int
defaultChunkKilos = 8192  -- 8MB chunks for optimal throughput

-- Spacing between seeds for different threads to prevent overlap (1 billion keys ~ 1TB data)
-- This ensures that threads in the same run never collide.
threadSeedSpacing :: Word64
threadSeedSpacing = 1000000000

lookupChunkKilos :: IO Int
lookupChunkKilos = do
  mChunk <- lookupEnv "REDIS_CLIENT_FILL_CHUNK_KB"
  case mChunk >>= readMaybe of
    Just n | n > 0 -> return n
    _ -> return defaultChunkKilos


-- | Fills the cache with roughly the requested GB of data.
fillCacheWithData :: (Client client) => Word64 -> Int -> Int -> RedisCommandClient client ()
fillCacheWithData baseSeed threadIdx gb = fillCacheWithDataMB baseSeed threadIdx (gb * 1024)

-- | Fills the cache with roughly the requested MB of data.
-- This allows finer-grained parallelization.
fillCacheWithDataMB :: (Client client) => Word64 -> Int -> Int -> RedisCommandClient client ()
fillCacheWithDataMB baseSeed threadIdx mb = do
  ClientState client _ <- State.get
  -- deterministic start seed for this thread based on the global baseSeed
  let startSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
  
  chunkKilos <- liftIO lookupChunkKilos
  
  -- We turn off client replies to maximize write throughput (Fire and Forget)
  -- This is safe in this threaded context because each thread has its own
  -- isolated connection to Redis, so the "CLIENT REPLY OFF" state only
  -- affects this specific connection.
  clientReply OFF
  
  -- Calculate total chunks needed based on actual MB requested
  let totalKilosNeeded = mb * 1024  -- Convert MB to KB
      totalChunks = (totalKilosNeeded + chunkKilos - 1) `div` chunkKilos  -- Ceiling division
  
  -- Send all chunks sequentially (fire-and-forget mode)
  mapM_ (\i -> do 
      let !cmd = genRandomSet chunkKilos (startSeed + fromIntegral i)
      send client cmd
      ) [0..totalChunks - 1]
  
  -- Turn replies back on to confirm completion
  val <- clientReply ON
  case val of 
    Just _ -> do
      _ <- dbsize -- Consume the response
      return ()
    Nothing -> error "clientReply returned an unexpected value"

-- | Cluster-aware fill function using pipelining with slot-specific keys
-- This version fills data for keys that hash to a specific slot range
-- Uses CLIENT REPLY OFF/ON for consistency with non-clustered fill
-- Note: Hash tag {sN} ensures keys route to same node, but doesn't guarantee
-- routing to slot N specifically. Relies on thread's direct connection to target node.
fillCacheWithDataClusterPipelined :: (Client client) => 
  Word64 ->      -- Base seed for deterministic key generation
  Int ->         -- Thread index
  Int ->         -- MB to fill
  Word16 ->      -- Target slot number (0-16383) - used for hash tag
  client 'Connected -> 
  IO ()
fillCacheWithDataClusterPipelined baseSeed threadIdx mb targetSlot client = do
  -- deterministic start seed for this thread based on the global baseSeed
  let startSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
  
  chunkKilos <- lookupChunkKilos
  
  -- Calculate total chunks needed based on actual MB requested
  let totalKBNeeded = mb * 1024  -- Convert MB to KB
      totalChunks = (totalKBNeeded + chunkKilos - 1) `div` chunkKilos  -- Ceiling division
  
  printf "Thread %d: Filling %d MB (%d chunks) for slot %d with pipelining...\n" 
    threadIdx mb totalChunks targetSlot
  
  -- Use CLIENT REPLY OFF/ON similar to non-clustered mode
  -- Turn off client replies for fire-and-forget pipelining
  send client (Builder.toLazyByteString $ encode $ RespArray [RespBulkString "CLIENT", RespBulkString "REPLY", RespBulkString "OFF"])
  _ <- receive client  -- Consume the OK response
  
  -- Generate commands with hash tag to route to target slot
  -- Hash tag format: {sN} where N is the target slot number
  -- Note: The CRC16 of {sN} determines actual slot routing, not N directly
  -- Thread connects to node owning targetSlot, so commands reach correct node
  let hashTagStr = printf "{s%d}" targetSlot :: String
      hashTag = BSC.pack hashTagStr
  
  -- Pipeline all chunks (fire-and-forget mode) using the noise buffer
  mapM_ (\chunkIdx -> do
      let chunkSeed = startSeed + fromIntegral chunkIdx
          cmd = genRandomSetWithHashTag chunkKilos chunkSeed hashTag
      send client cmd
    ) [0..totalChunks - 1]
  
  -- Turn replies back on to confirm completion
  send client (Builder.toLazyByteString $ encode $ RespArray [RespBulkString "CLIENT", RespBulkString "REPLY", RespBulkString "ON"])
  _ <- receive client  -- Consume the OK response
  
  printf "Thread %d: Completed filling %d MB for slot %d\n" threadIdx mb targetSlot

-- | Generate SET commands with a hash tag prefix to ensure slot routing
genRandomSetWithHashTag :: Int -> Word64 -> BS.ByteString -> LB.ByteString
genRandomSetWithHashTag chunkKilos seed hashTag = Builder.toLazyByteString $! go numCommands seed
  where
    numCommands = chunkKilos
    hashTagLen = BS.length hashTag
    
    -- Pre-computed RESP protocol prefix for SET commands
    -- Key format: {hashTag}:{512 bytes from generate512Bytes}
    -- Total key length: hashTagLen + 1 (colon) + 512
    setPrefix :: Builder.Builder
    setPrefix = Builder.stringUtf8 "*3\r\n$3\r\nSET\r\n$" 
      <> Builder.intDec (hashTagLen + 1 + 512)  -- hash tag + ":" + 512 bytes (8 byte seed + 504 bytes noise)
      <> Builder.stringUtf8 "\r\n"
      <> Builder.byteString hashTag
      <> Builder.char8 ':'
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
      let !keySeed = s
          !valSeed = s * 6364136223846793005 + 1442695040888963407
          !nextSeed = valSeed * 6364136223846793005 + 1442695040888963407
          !keyData = generate512Bytes keySeed
          !valData = generate512Bytes valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}
    
    -- Generate exactly 512 bytes efficiently (8 bytes unique seed + 504 bytes noise)
    -- This is the same as the non-clustered version
    generate512Bytes :: Word64 -> Builder.Builder
    generate512Bytes !s = 
        let !scrambled = s * 6364136223846793005 + 1442695040888963407
            !offset = fromIntegral (scrambled `rem` (128 * 1024 * 1024 - 512))
            !chunk = BS.take 504 (BS.drop offset randomNoise)
        in Builder.word64LE s <> Builder.byteString chunk
    {-# INLINE generate512Bytes #-}

-- | Cluster-aware fill function that uses the RedisCommands interface (backward compatibility)
-- This works with any monad that implements RedisCommands (including ClusterCommandClient)
--
-- PERFORMANCE NOTE: This implementation does not use CLIENT REPLY OFF or pipelining
-- because the RedisCommands interface waits for a response after each command.
-- For fire-and-forget pipelining, use fillCacheWithDataClusterPipelined instead.
--
-- Current approach: Simpler implementation using RedisCommands for correctness,
-- accepting the performance trade-off of waiting for each response.
fillCacheWithDataCluster :: (RedisCommands m, MonadIO m) => Word64 -> Int -> Int -> m ()
fillCacheWithDataCluster baseSeed threadIdx mb = do
  -- deterministic start seed for this thread based on the global baseSeed
  let startSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
  
  chunkKilos <- liftIO lookupChunkKilos
  
  -- Calculate total commands needed
  let totalKilosNeeded = mb * 1024  -- Convert MB to KB
      totalChunks = (totalKilosNeeded + chunkKilos - 1) `div` chunkKilos  -- Ceiling division
      totalCommands = totalChunks * chunkKilos
  
  liftIO $ printf "Thread %d: Filling %d MB (%d commands)...\n" threadIdx mb totalCommands
  
  -- Generate and execute SET commands
  -- Each command waits for response from cluster (cannot use fire-and-forget with RedisCommands)
  mapM_ (\cmdIdx -> do
      let keySeed = startSeed + fromIntegral cmdIdx
          -- Generate key as hex string (printable and safe)
          keyStr = "cluster:" ++ show threadIdx ++ ":" ++ printf "%016x" keySeed
          valStr = replicate 512 'x' -- Simple value placeholder
      -- Use the RedisCommands interface which handles cluster routing
      _ <- set keyStr valStr
      return ()
    ) [0..totalCommands - 1]
  
  liftIO $ printf "Thread %d: Completed filling %d MB\n" threadIdx mb