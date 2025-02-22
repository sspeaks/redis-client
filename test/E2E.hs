{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient)
import Control.Monad.State qualified as State
import Data.ByteString.Char8 qualified as BSC
import RedisCommandClient (RedisCommandClient, RedisCommands (..), RunState (..), runCommandsAgainstPlaintextHost)
import Resp
  ( Encodable (encode),
    RespData (RespArray, RespBulkString, RespSimpleString),
    parseManyWith,
  )
import Test.Hspec

runRedisAction :: RedisCommandClient PlainTextClient a -> IO a
runRedisAction = runCommandsAgainstPlaintextHost (RunState "redis.local" "" False 0 False)

main :: IO ()
main = hspec $ do
  describe "Can run basic operations" $ do
    it "set is encoded and responded to properly" $ do
      runRedisAction (set "hello" "world") `shouldReturn` RespSimpleString "OK"
    it "get is encoded properly and fetches the key set previously" $ do
      runRedisAction (get "hello") `shouldReturn` RespBulkString "world"
    it "ping is encoded properly and returns pong" $ do
      runRedisAction ping `shouldReturn` RespSimpleString "PONG"
    it "bulkSet is encoded properly and subsequent gets work properly" $ do
      runRedisAction (bulkSet [("a", "b"), ("c", "d"), ("e", "f")]) `shouldReturn` RespSimpleString "OK"
      runRedisAction (get "a") `shouldReturn` RespBulkString "b"
      runRedisAction (get "c") `shouldReturn` RespBulkString "d"
      runRedisAction (get "e") `shouldReturn` RespBulkString "f"

  describe "Pipelining works" $ do
    it "can pipeline 100 commands" $ do
      runRedisAction
        ( do
            client <- State.get
            send client $ mconcat ([encode . RespArray $ map RespBulkString ["SET", "KEY" <> BSC.pack (show n), "VALUE" <> BSC.pack (show n)] | n <- [1 .. 100]])
            parseManyWith 100 (recieve client)
        )
        `shouldReturn` replicate 100 (RespSimpleString "OK")
    it "can retrieve 100 command results with pipelining" $ do
      runRedisAction
        ( do
            client <- State.get
            send client $ mconcat ([encode . RespArray $ map RespBulkString ["GET", "KEY" <> BSC.pack (show n)] | n <- [1 .. 100]])
            parseManyWith 100 (recieve client)
        )
        `shouldReturn` [RespBulkString ("VALUE" <> BSC.pack (show n)) | n <- [1 .. 100]]
