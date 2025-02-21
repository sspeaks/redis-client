{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import RedisCommandClient

maxRecvBytes :: Int
maxRecvBytes = 4096

main :: IO ()
main =
  runCommandsAgainstTLSHost "sspeaks-swec-test-1p-cust-appr.cache.icbbvt.windows-int.net" $ do
    auth "<password>" >>= (liftIO . print)
    ping >>= (liftIO . print)
    set "hello" "world" >>= (liftIO . print)
    get "hello" >>= (liftIO . print)
    bulkSet [(show a, show a) | a <- [0 .. 100]] >>= (liftIO . print)
    forM_ [0 .. 100] $ \a -> get (show a) >>= (liftIO . print)
