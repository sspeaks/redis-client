{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..))
import Control.Monad (forM, replicateM, replicateM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State qualified as State
import Data.ByteString (ByteString)
import RedisCommandClient
import Resp (RespData (..), encode, parseManyWith)
import System.Random.Stateful

randomBytes :: (StatefulGen g m) => g -> m ByteString
randomBytes = uniformByteStringM 512

genRandomSet :: (StatefulGen g m) => g -> m ByteString
genRandomSet gen = do
  key <- randomBytes gen
  value <- randomBytes gen
  return $ encode . RespArray $ map RespBulkString ["SET", key, value]

numToPipeline :: Int
numToPipeline = 1024 -- 1024 * 256 -- 256 Mb per fill

main :: IO ()
main =
  runCommandsAgainstTLSHost "sspeaks-swec-test-1p-desktop.cache.icbbvt.windows-int.net" $ do
    auth "<password>" >>= (liftIO . print)
    flushAll >>= (liftIO . print)
    ping >>= (liftIO . print)
    set "hello2" "world2" >>= (liftIO . print)
    get "hello2" >>= (liftIO . print)
    client <- State.get
    gen <- newIOGenM (mkStdGen 1234)
    replicateM_ 500 $ do
      setPipe <- mconcat <$> replicateM numToPipeline (genRandomSet gen)
      send client setPipe
      parseManyWith numToPipeline (recieve client) >>= (liftIO . print)
    dbsize >>= (liftIO . print)
    liftIO $ print ("Done" :: String)
    return ()

-- bulkSet [(show a, show (a + 1)) | a <- ([0 .. 100] :: [Int])] >>= (liftIO . print)
-- forM_ ([0 .. 100] :: [Int]) $ \a -> get (show a) >>= (liftIO . print)
