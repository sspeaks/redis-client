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
    it "set" $ do
      runRedisAction (set "hello" "world") `shouldReturn` RespSimpleString "OK"
    it "get" $ do
      runRedisAction (get "hello") `shouldReturn` RespBulkString "world"
    it "ping" $ do
      runRedisAction ping `shouldReturn` RespSimpleString "PONG"
    it "bulkSet" $ do
      runRedisAction (bulkSet [("a", "b"), ("c", "d"), ("e", "f")]) `shouldReturn` RespSimpleString "OK"
      runRedisAction (get "a") `shouldReturn` RespBulkString "b"
      runRedisAction (get "c") `shouldReturn` RespBulkString "d"
      runRedisAction (get "e") `shouldReturn` RespBulkString "f"
