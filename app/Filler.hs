{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}


module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM, replicateM_)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State qualified as State
import Data.Attoparsec.ByteString.Lazy qualified as Atto
import Data.ByteString qualified as SB
import Data.ByteString.Builder (stringUtf8)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (RedisCommandClient, RedisCommands (dbsize))
import Resp (Encodable (..), RespData (..), parseManyWith)
import System.Random (mkStdGen)
import System.Random.Stateful (StatefulGen, newIOGenM, uniformByteStringM)
import Text.Printf (printf)


randomBytes :: (StatefulGen g m) => g -> Int -> m SB.ByteString
randomBytes g b = uniformByteStringM b g

genRandomSet :: (StatefulGen g m) => g -> m LB.ByteString
genRandomSet gen = do
  bytesToSend <- LB.fromStrict <$> randomBytes gen (1024 * 1024 * 256) -- 256 MB of bytes
  case Atto.parseOnly (Atto.count (1024 * 256) parseSet) bytesToSend of
    Left err -> error err
    Right v -> return $ Builder.toLazyByteString $ mconcat v
  where
    -- return $ encode . RespArray $ map RespBulkString ["SET", key, value]
    setBuilder :: Builder.Builder
    setBuilder = stringUtf8 "*3\r\n" <> (encode . RespBulkString $ "SET")
    parseSet :: Atto.Parser Builder.Builder
    parseSet = do
      key <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      val <- encode . RespBulkString . LB.fromStrict <$> Atto.take 512
      return $ setBuilder <> key <> val

numToPipeline :: Int
numToPipeline = 1024 * 256

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  client <- State.get
  -- Open /dev/random in ReadMode
  seed <- liftIO $ round <$> getPOSIXTime
  gen <- newIOGenM (mkStdGen seed)
  doneMvar <- liftIO newEmptyMVar
  _ <- liftIO $ forkIO (readerThread client gb doneMvar)
  replicateM_ (4 * gb) $ do
    _ <- liftIO (genRandomSet gen) >>= send client
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

replicateM' :: (Applicative m) => Int -> m a -> m [a]
replicateM' n ls = go n (pure id)
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
readerThread client numToRead errorOrDone = do
  !reses <- replicateM' (4 * numToRead) $ do
    !res <- find isError <$> parseManyWith numToPipeline (recieve client)
    return res
  liftIO $ case extractError <$> catMaybes reses of
    [] -> putMVar errorOrDone $ Right ()
    (s : _) -> putMVar errorOrDone $ Left s
  where
    isError (RespError _) = True
    isError _ = False
    extractError (RespError e) = e
    extractError _ = error "won't happen"