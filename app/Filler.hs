{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.Attoparsec.ByteString.Lazy qualified as Atto
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.Foldable (forM_)
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import RedisCommandClient (RedisCommandClient, RedisCommands (dbsize))
import Resp (Encodable (..), RespData (..), parseManyWith)
import Text.Printf (printf)

oneGig :: Int -> LB.ByteString
oneGig start =
  let sizeInBytes = 1024 * 1024 * 1024 -- 1GB
      numWords = sizeInBytes `div` 4 -- Number of 4-byte words
      builder = foldMap word32ToBuilder [fromIntegral start .. fromIntegral (numWords - 1 + start)]
   in Builder.toLazyByteString builder

-- Helper function to convert Word32 to ByteString Builder
word32ToBuilder :: Word32 -> Builder.Builder
word32ToBuilder = Builder.word32LE -- Directly write Word32 in little-endian order

genRandomSet :: Int -> LB.ByteString
genRandomSet gen = do
  let bytesToSend = oneGig gen
  case Atto.parseOnly (Atto.count numKilosToPipeline parseSet) bytesToSend of
    Left err -> error err
    Right v -> Builder.toLazyByteString $ mconcat v
  where
    setBuilder :: Builder.Builder
    setBuilder = Builder.stringUtf8 "*3\r\n" <> (encode . RespBulkString $ "SET")
    parseSet :: Atto.Parser Builder.Builder
    parseSet = do
      key <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      val <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      return $ setBuilder <> key <> val

numKilosToPipeline :: Int
numKilosToPipeline = 1024 * 1024 -- 1 gigabyte

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  client <- State.get
  -- seed <- liftIO $ round <$> getPOSIXTime
  -- gen <- newIOGenM (mkStdGen seed)
  doneMvar <- liftIO newEmptyMVar
  _ <- liftIO $ forkIO (readerThread client gb doneMvar)
  forM_ [1 .. gb] $ \iter -> do
    _ <- send client (genRandomSet iter)
    liftIO $ printf "+1GB written in fireAndForget mode\n"
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

replicateM' :: (Applicative m) => Int -> m a -> m [a]
replicateM' num ls = go num (pure id)
  where
    go n fs
      | n <= 0 = do
          f <- fs
          pure (f [])
      | otherwise = go (n - 1) gs
      where
        gs = do
          f <- fs
          l <- ls
          pure (f . (l :))

readerThread :: (Client client) => client 'Connected -> Int -> MVar (Either String ()) -> IO ()
readerThread client numGbToRead errorOrDone = do
  !reses <- replicateM' numGbToRead $ do
    !res <- find isError <$> parseManyWith numKilosToPipeline (recieve client)
    return res
  liftIO $ case extractError <$> catMaybes reses of
    [] -> putMVar errorOrDone $ Right ()
    (s : _) -> putMVar errorOrDone $ Left s
  where
    isError (RespError _) = True
    isError _ = False
    extractError (RespError e) = e
    extractError _ = error "won't happen"