{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import           Client                  (Client (..))
import           Control.Monad           (when)
import qualified Control.Monad.State     as State
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LB
import           Data.Word               (Word64)
import           FillHelpers             (generateBytes, randomNoise)
import           RedisCommandClient      (ClientReplyValues (OFF, ON),
                                          ClientState (..), RedisCommandClient,
                                          RedisCommands (clientReply, dbsize))
import           Text.Printf             (printf)

-- | Forces evaluation of the noise buffer to ensure it is shared and ready.
initRandomNoise :: IO ()
initRandomNoise = do
    let !len = BS.length randomNoise
    printf "Initialized shared random noise buffer: %d MB\n" (len `div` (1024 * 1024))

genRandomSet :: Int -> Int -> Int -> Word64 -> LB.ByteString
genRandomSet batchSize keySize valueSize seed = Builder.toLazyByteString $! go numCommands seed
  where
    numCommands = batchSize

    -- Pre-computed RESP protocol prefix for SET commands with dynamic key size
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
      let !keySeed = s
          !valSeed = s * 6364136223846793005 + 1442695040888963407
          !nextSeed = valSeed * 6364136223846793005 + 1442695040888963407
          !keyData = generateBytes keySize keySeed
          !valData = generateBytes valueSize valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}

-- Spacing between seeds for different threads to prevent overlap (1 billion keys ~ 1TB data)
-- This ensures that threads in the same run never collide.
threadSeedSpacing :: Word64
threadSeedSpacing = 1000000000

-- | Fills the cache with roughly the requested GB of data.
fillCacheWithData :: (Client client) => Word64 -> Int -> Int -> Int -> Int -> Int -> RedisCommandClient client ()
fillCacheWithData baseSeed threadIdx gb = fillCacheWithDataMB baseSeed threadIdx (gb * 1024)

-- | Fills the cache with roughly the requested MB of data.
-- This allows finer-grained parallelization.
fillCacheWithDataMB :: (Client client) => Word64 -> Int -> Int -> Int -> Int -> Int -> RedisCommandClient client ()
fillCacheWithDataMB baseSeed threadIdx mb pipelineBatchSize keySize valueSize = do
  ClientState client _ <- State.get
  -- deterministic start seed for this thread based on the global baseSeed
  let startSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)

  -- We turn off client replies to maximize write throughput (Fire and Forget)
  -- This is safe in this threaded context because each thread has its own
  -- isolated connection to Redis, so the "CLIENT REPLY OFF" state only
  -- affects this specific connection.
  clientReply OFF

  -- Calculate total commands needed based on actual data size
  -- Each command stores: keySize bytes (key) + valueSize bytes (value)
  let bytesPerCommand = keySize + valueSize
      totalBytesNeeded = mb * 1024 * 1024  -- Convert MB to bytes
      totalCommandsNeeded = (totalBytesNeeded + bytesPerCommand - 1) `div` bytesPerCommand  -- Ceiling division

      -- Calculate chunks and remainder for exact distribution
      fullChunks = totalCommandsNeeded `div` pipelineBatchSize
      remainderCommands = totalCommandsNeeded `mod` pipelineBatchSize

  -- Send all full chunks sequentially (fire-and-forget mode)
  mapM_ (\i -> do
      let !cmd = genRandomSet pipelineBatchSize keySize valueSize (startSeed + fromIntegral i)
      send client cmd
      ) [0..fullChunks - 1]

  -- Send the remainder chunk if there is one
  when (remainderCommands > 0) $ do
      let !cmd = genRandomSet remainderCommands keySize valueSize (startSeed + fromIntegral fullChunks)
      send client cmd

  -- Turn replies back on to confirm completion
  val <- clientReply ON
  case val of
    Just _ -> do
      _ <- dbsize -- Consume the response
      return ()
    Nothing -> error "clientReply returned an unexpected value"
