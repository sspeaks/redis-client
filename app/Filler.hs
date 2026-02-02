{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (dbsize, clientReply), ClientReplyValues (OFF, ON))
import Resp (RespData (..))
import System.Environment (lookupEnv)
import Data.Word (Word64)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- Simple fast PRNG that directly generates Builder output
gen :: Word64 -> Builder.Builder
gen s = Builder.word64LE s <> gen (s * 1664525 + 1013904223)
{-# INLINE gen #-}

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
          !valSeed = s * 1664525 + 1013904223
          !nextSeed = valSeed * 1664525 + 1013904223
          !keyData = generate512Bytes keySeed
          !valData = generate512Bytes valSeed
      in setPrefix <> keyData <> valuePrefix <> valData <> commandSuffix <> go (n - 1) nextSeed
    {-# INLINE go #-}
    
    -- Generate exactly 512 bytes efficiently (64 Word64s)
    generate512Bytes :: Word64 -> Builder.Builder
    generate512Bytes !s = generateWords64 64 s
      where
        generateWords64 :: Int -> Word64 -> Builder.Builder
        generateWords64 0 _ = mempty
        generateWords64 n !seed1 = 
          let !nextSeed = seed1 * 1664525 + 1013904223
          in Builder.word64LE seed1 <> generateWords64 (n - 1) nextSeed
        {-# INLINE generateWords64 #-}
    {-# INLINE generate512Bytes #-}

defaultChunkKilos :: Int
defaultChunkKilos = 2048  -- 2MB chunks for optimal throughput

lookupChunkKilos :: IO Int
lookupChunkKilos = do
  mChunk <- lookupEnv "REDIS_CLIENT_FILL_CHUNK_KB"
  case mChunk >>= readMaybe of
    Just n | n > 0 -> return n
    _ -> return defaultChunkKilos

lookupPipelineSize :: IO Int
lookupPipelineSize = do
  mPipeline <- lookupEnv "REDIS_CLIENT_PIPELINE_SIZE"
  case mPipeline >>= readMaybe of
    Just n | n > 0 -> return n
    _ -> return 1000  -- Default pipeline size optimized for throughput

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  ClientState client _ <- State.get
  seed <- liftIO $ round <$> getPOSIXTime
  chunkKilos <- liftIO lookupChunkKilos
  pipelineSize <- liftIO lookupPipelineSize
  clientReply OFF
  
  -- Calculate total chunks needed based on actual GB requested
  let totalKilosNeeded = gb * 1024 * 1024  -- Convert GB to KB
      totalChunks = (totalKilosNeeded + chunkKilos - 1) `div` chunkKilos  -- Ceiling division
      batches = (totalChunks + pipelineSize - 1) `div` pipelineSize
  
  liftIO $ printf "Filling %d GB (%d KB) using %d chunks of %d KB each\n" 
                  gb totalKilosNeeded totalChunks chunkKilos
  
  -- Use pipelining for better throughput
  mapM_ (\batchNum -> do
    let startIdx = batchNum * pipelineSize
        remainingChunks = totalChunks - startIdx
        currentBatchSize = min pipelineSize remainingChunks
    -- Generate and send a batch of commands with unique seeds
    let commands = [genRandomSet chunkKilos (fromIntegral seed + fromIntegral i) | i <- [startIdx..startIdx + currentBatchSize - 1]]
    mapM_ (send client) commands
    liftIO $ printf "+%d chunks (%dKB each) written in pipelined batch %d/%d\n" 
                    currentBatchSize chunkKilos (batchNum + 1) batches
    ) [0..batches-1]
  
  val <- clientReply ON
  case val of 
    Just _ -> do
      keys <- extractInt <$> dbsize
      liftIO $ printf "Finished filling cache with %d GB using %d chunks of ~%dKB each. Wrote %d keys\n" 
                      gb totalChunks chunkKilos keys
    Nothing -> error "clientReply returned an unexpected value"
  where
    extractInt (RespInteger i) = i
    extractInt _ = error "Expected RespInteger"