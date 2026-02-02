{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..))
import Control.Monad (replicateM)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.Attoparsec.ByteString.Lazy qualified as Atto
import Data.ByteString qualified as SB
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (dbsize, clientReply), ClientReplyValues (OFF, ON))
import Resp (Encodable (..), RespData (..))
import System.Environment (lookupEnv)
import System.Random (mkStdGen)
import System.Random.Stateful (StatefulGen, newIOGenM, uniformByteStringM)
import Text.Printf (printf)
import Text.Read (readMaybe)

randomBytes :: (StatefulGen g m) => g -> Int -> m SB.ByteString
randomBytes g b = uniformByteStringM b g

genRandomSet :: (StatefulGen g m) => Int -> g -> m LB.ByteString
genRandomSet chunkKilos gen = do
  !bytesToSend <- LB.fromStrict <$> randomBytes gen (chunkKilos * 1024)
  case Atto.parseOnly (Atto.count chunkKilos parseSet) bytesToSend of
    Left err -> error err
    Right v -> return $! Builder.toLazyByteString $! mconcat v
  where
    -- return $ encode . RespArray $ map RespBulkString ["SET", key, value]
    setBuilder :: Builder.Builder
    setBuilder = Builder.stringUtf8 "*3\r\n" <> (encode . RespBulkString $ "SET")
    parseSet :: Atto.Parser Builder.Builder
    parseSet = do
      !key <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      !val <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      return $! setBuilder <> key <> val

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
  gen <- newIOGenM (mkStdGen seed)
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
    let remainingChunks = totalChunks - (batchNum * pipelineSize)
        currentBatchSize = min pipelineSize remainingChunks
    -- Generate and send a batch of commands
    commands <- liftIO $ replicateM currentBatchSize (genRandomSet chunkKilos gen)
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