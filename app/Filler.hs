{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (dbsize, clientReply), ClientReplyValues (OFF, ON))
import System.Environment (lookupEnv)
import Data.Word (Word64, Word8)
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