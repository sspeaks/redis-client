{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Filler where

import Client (Client (..), ConnectionStatus (Connected))
import Control.Concurrent (MVar, ThreadId, forkIO, myThreadId, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Exception (IOException, catch)
import Control.Monad (replicateM_)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State (evalStateT)
import Control.Monad.State qualified as State
import Data.Attoparsec.ByteString.Lazy qualified as Atto
import Data.ByteString qualified as SB
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (dbsize), parseManyWith)
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
defaultChunkKilos = 1024 * 1024 -- 1 gigabyte worth of data

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
  doneMvar <- liftIO newEmptyMVar
  parentThread <- liftIO myThreadId
  _ <- liftIO $ forkIO (readerThread parentThread client chunkKilos gb doneMvar)
  replicateM_ gb $ do
    _ <- liftIO (genRandomSet chunkKilos gen) >>= send client
    liftIO $ printf "+%dKB chunk written in fireAndForget mode\n" chunkKilos
  liftIO $ printf "Done writing... waiting on read thread to finish...\n"
  result <- liftIO $ takeMVar doneMvar
  case result of
    Left s -> error $ printf "Error: %s\n" s
    Right () -> do
      keys <- extractInt <$> dbsize
      liftIO $ printf "Finished filling cache with %d chunk(s) of ~%dKB each. Wrote %d keys\n" gb chunkKilos keys
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