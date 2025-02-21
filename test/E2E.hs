{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (PlainTextClient)
import RedisCommandClient
  ( RedisCommandClient,
    RedisCommands (..),
    runCommandsAgainstPlaintextHost,
  )
import Resp (RespData (RespArray, RespBulkString, RespSimpleString))
import Test.Hspec

runRedisAction :: RedisCommandClient PlainTextClient a -> IO a
runRedisAction = runCommandsAgainstPlaintextHost "redis.local"

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
