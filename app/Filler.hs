{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM, replicateM_)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.ByteString qualified as B
import Data.Maybe (isJust)
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (RedisCommandClient, RedisCommands (dbsize))
import Resp (Encodable (..), RespData (..), parseManyWith)
import System.Random.Stateful (StatefulGen, mkStdGen, newIOGenM, uniformByteStringM)
import Text.Printf (printf)

randomBytes :: (StatefulGen g m) => g -> m B.ByteString
randomBytes = uniformByteStringM 512

genRandomSet :: (StatefulGen g m) => g -> m B.ByteString
genRandomSet gen = do
  key <- randomBytes gen
  value <- randomBytes gen
  return $ encode . RespArray $ map RespBulkString ["SET", key, value]

numToPipeline :: Int
numToPipeline = 1024 * 256

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  client <- State.get
  seed <- liftIO $ round <$> getPOSIXTime
  gen <- newIOGenM (mkStdGen seed)
  doneMvar <- liftIO newEmptyMVar
  _ <- liftIO $ forkIO (readerThread client gb doneMvar)
  replicateM_ (4 * gb) $ do
    setPipe <- mconcat <$> replicateM numToPipeline (genRandomSet gen)
    send client setPipe
    liftIO $ printf "+256MB written in fireAndForget mode\n"
  liftIO $ printf "Done writing... waiting on read thread to finish...\n"
  result <- liftIO $ takeMVar doneMvar
  case result of
    Left s -> error $ printf "Error: %s\n" s
    Right () -> do
      keys <- extractInt <$> dbsize
      liftIO $ printf "Finished filling cache with %dGB of data. Wrote %d keys\n" gb keys
  where
    extractInt (RespInteger i) = i
    extractInt _ = error "Expected RespInteger"

readerThread :: (Client client) => client 'Connected -> Int -> MVar (Either String ()) -> IO ()
readerThread client numToRead errorOrDone = do
  result <- foldr (\x acc -> if isJust acc then acc else isError x) Nothing <$> parseManyWith (numToPipeline * 4 * numToRead) (recieve client)
  liftIO $ case result of
    Nothing -> putMVar errorOrDone $ Right ()
    Just s -> putMVar errorOrDone $ Left s
  where
    isError (RespError e) = Just e
    isError _ = Nothing