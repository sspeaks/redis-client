{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler
  ( initRandomNoise
  , genRandomSet
  , fillCacheWithData
  , fillCacheWithDataMB
  , sendChunkedFill
  ) where

import           Client                  (Client (..))
import           Control.Monad           (when)
import qualified Control.Monad.State     as State
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LBS
import           Data.Word               (Word64)
import           FillHelpers             (generateBytes, nextLCG, randomNoise,
                                         threadSeedSpacing)
import           RedisCommandClient      (ClientReplyValues (OFF, ON),
                                          ClientState (..), RedisCommandClient,
                                          RedisCommands (clientReply, dbsize))
import           Text.Printf             (printf)

-- | Forces evaluation of the noise buffer to ensure it is shared and ready.
initRandomNoise :: IO ()
initRandomNoise = do
    let !len = BS.length randomNoise
    printf "Initialized shared random noise buffer: %d MB\n" (len `div` (1024 * 1024))

genRandomSet :: Int -> Int -> Int -> Word64 -> LBS.ByteString
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
          !valSeed = nextLCG s
          !nextSeed = nextLCG valSeed
          !keyData = generateBytes keySize keySeed
          !valData = generateBytes valueSize valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}

-- | Fills the cache with roughly the requested GB of data.
fillCacheWithData :: (Client client) => Word64 -> Int -> Int -> Int -> Int -> Int -> RedisCommandClient client ()
fillCacheWithData baseSeed threadIdx gb = fillCacheWithDataMB baseSeed threadIdx (gb * 1024)

-- | Fills the cache with roughly the requested MB of data.
-- This allows finer-grained parallelization.
fillCacheWithDataMB :: (Client client) => Word64 -> Int -> Int -> Int -> Int -> Int -> RedisCommandClient client ()
fillCacheWithDataMB baseSeed threadIdx mb pipelineBatchSize keySize valueSize = do
  let startSeed = baseSeed + (fromIntegral threadIdx * threadSeedSpacing)
      genChunk batchSize seed = genRandomSet batchSize keySize valueSize seed

  -- We turn off client replies to maximize write throughput (Fire and Forget)
  -- This is safe in this threaded context because each thread has its own
  -- isolated connection to Redis, so the "CLIENT REPLY OFF" state only
  -- affects this specific connection.
  _ <- clientReply OFF
  sendChunkedFill genChunk mb pipelineBatchSize (keySize + valueSize) startSeed

  -- Turn replies back on to confirm completion
  val <- clientReply ON
  case val of
    Just _ -> do
      _ <- dbsize -- Consume the response
      return ()
    Nothing -> error "clientReply returned an unexpected value"

-- | Send chunked data to Redis in pipeline batches. Calculates the number of
-- full chunks and remainder, then sends each via fire-and-forget.
sendChunkedFill ::
  (Client client) =>
  (Int -> Word64 -> LBS.ByteString) -> -- chunk generator (batchSize -> seed -> data)
  Int ->    -- total MB to fill
  Int ->    -- pipeline batch size
  Int ->    -- bytes per command (keySize + valueSize)
  Word64 -> -- start seed
  RedisCommandClient client ()
sendChunkedFill genChunk mb pipelineBatchSize bytesPerCommand startSeed = do
  ClientState client _ <- State.get
  let totalBytesNeeded = mb * 1024 * 1024
      totalCommandsNeeded = (totalBytesNeeded + bytesPerCommand - 1) `div` bytesPerCommand
      fullChunks = totalCommandsNeeded `div` pipelineBatchSize
      remainderCommands = totalCommandsNeeded `mod` pipelineBatchSize

  mapM_ (\i -> do
      let !cmd = genChunk pipelineBatchSize (startSeed + fromIntegral i)
      send client cmd
      ) [0..fullChunks - 1]

  when (remainderCommands > 0) $ do
      let !cmd = genChunk remainderCommands (startSeed + fromIntegral fullChunks)
      send client cmd
