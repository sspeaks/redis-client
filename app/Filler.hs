{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Concurrent (MVar, ThreadId, forkIO, myThreadId, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Exception (IOException, catch)
import Control.Monad (replicateM, replicateM_, when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State (evalStateT)
import Control.Monad.State qualified as State
import Data.ByteString qualified as SB
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (ClientState (..), RedisCommandClient (runRedisCommandClient), RedisCommands (dbsize), parseManyWith, fastCountResponses)
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
  -- Pre-compute the constant parts of the SET command
  let setPrefix = Builder.stringUtf8 "*3\r\n" <> (encode . RespBulkString $ "SET")
      -- Each SET command is: setPrefix + key (512 bytes) + value (512 bytes)
      -- Total per command: ~1KB
  -- Generate all SET commands directly without parsing
  builders <- replicateM chunkKilos $ do
    !keyBytes <- randomBytes gen 512
    !valBytes <- randomBytes gen 512
    let !keyBuilder = encode . RespBulkString . LB.fromStrict $ keyBytes
        !valBuilder = encode . RespBulkString . LB.fromStrict $ valBytes
    return $! setPrefix <> keyBuilder <> valBuilder
  -- Use strict evaluation to force the computation and reduce memory usage
  let !result = Builder.toLazyByteString $! mconcat builders
  return result

defaultChunkKilos :: Int
defaultChunkKilos = 10240 -- 10MB worth of data (increased from 1GB)

lookupChunkKilos :: IO Int
lookupChunkKilos = do
  mChunk <- lookupEnv "REDIS_CLIENT_FILL_CHUNK_KB"
  case mChunk >>= readMaybe of
    Just n | n > 0 -> return n
    _ -> return defaultChunkKilos

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  ClientState client _ <- State.get
  seed <- liftIO $ round <$> getPOSIXTime
  gen <- newIOGenM (mkStdGen seed)
  chunkKilos <- liftIO lookupChunkKilos
  -- Calculate number of iterations needed to reach the desired total size
  -- gb is in gigabytes, chunkKilos is in kilobytes, so we need to convert
  let totalKilos = gb * 1024 * 1024  -- Convert GB to KB
      numIterations = (totalKilos + chunkKilos - 1) `div` chunkKilos  -- Ceiling division
      totalCommands = numIterations * chunkKilos  -- Total SET commands to send
  liftIO $ printf "Filling %d GB with chunks of %d KB (%d iterations, %d commands)\n" gb chunkKilos numIterations totalCommands
  doneMvar <- liftIO newEmptyMVar
  parentThread <- liftIO myThreadId
  _ <- liftIO $ forkIO (optimizedReaderThread parentThread client totalCommands doneMvar)
  replicateM_ numIterations $ do
    !chunk <- liftIO (genRandomSet chunkKilos gen)
    send client chunk
    liftIO $ printf "+%dKB chunk written in fireAndForget mode\n" chunkKilos
  liftIO $ printf "Done writing %d commands... waiting on read thread to finish...\n" totalCommands
  result <- liftIO $ takeMVar doneMvar
  case result of
    Left s -> error $ printf "Error: %s\n" s
    Right () -> do
      keys <- extractInt <$> dbsize
      liftIO $ printf "Finished filling cache with %d chunk(s) of ~%dKB each. Wrote %d keys\n" numIterations chunkKilos keys
  where
    extractInt (RespInteger i) = i
    extractInt _ = error "Expected RespInteger"

readerThread :: (Client client) => ThreadId -> client 'Connected -> Int -> Int -> MVar (Either String ()) -> IO ()
readerThread parentThread client chunkKilos numGbToRead errorOrDone =
  evalStateT -- use state monad to keep track of the parse buffer and not drop input
    ( do
        replicateM_ numGbToRead $ do
          !res <- find isError <$> parseManyWith chunkKilos (receive client)
          case extractError <$> res of
            Nothing -> return ()
            Just s -> fail ("error encountered from RESP values read from socket: " <> s)
        liftIO $ putMVar errorOrDone $ Right ()
    )
    (ClientState client SB.empty)
    `catch` (\e -> putMVar errorOrDone (Left $ "Exception: " ++ show (e :: IOException)) >> throwTo parentThread e)
  where
    isError (RespError _) = True
    isError _ = False
    extractError (RespError e) = e
    extractError _ = error "won't happen"

-- Optimized reader thread that counts responses instead of parsing them all
optimizedReaderThread :: (Client client) => ThreadId -> client 'Connected -> Int -> MVar (Either String ()) -> IO ()
optimizedReaderThread parentThread client totalCommands errorOrDone =
  evalStateT
    ( countResponses totalCommands 0 )
    (ClientState client SB.empty)
    `catch` (\e -> putMVar errorOrDone (Left $ "Exception: " ++ show (e :: IOException)) >> throwTo parentThread e)
  where
    countResponses :: (Client client) => Int -> Int -> State.StateT (ClientState client) IO ()
    countResponses total counted
      | counted >= total = liftIO $ putMVar errorOrDone $ Right ()
      | otherwise = do
          -- Use the fast response counting optimization instead of full parsing
          let batchSize = min (total - counted) 1000
          currentState <- State.get
          let fastCountAction = fastCountResponses batchSize (receive (getClient currentState))
          (actualCount, newState) <- liftIO $ State.runStateT (runRedisCommandClient fastCountAction) currentState
          State.put newState
          let newTotal = counted + actualCount
          when (newTotal `mod` 10000 == 0) $
            liftIO $ printf "Processed %d/%d responses\n" newTotal total
          countResponses total newTotal