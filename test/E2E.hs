{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient)
import Control.Monad (void)
import Control.Monad.State qualified as State
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as BSC
import RedisCommandClient (ClientState (..), RedisCommandClient, RedisCommands (..), RunState (..), parseManyWith, runCommandsAgainstPlaintextHost)
import Resp
  ( Encodable (encode),
    RespData (..),
  )
import Test.Hspec (before_, describe, hspec, it, shouldReturn)

runRedisAction :: RedisCommandClient PlainTextClient a -> IO a
runRedisAction = runCommandsAgainstPlaintextHost (RunState "redis.local" Nothing "" False 0 False)

main :: IO ()
main = hspec $ before_ (void $ runRedisAction flushAll) $ do
  describe "Can run basic operations: " $ do
    it "get and set are encoded and respond properly" $ do
      runRedisAction (set "hello" "world") `shouldReturn` RespSimpleString "OK"
      runRedisAction (get "hello") `shouldReturn` RespBulkString "world"
    it "ping is encoded properly and returns pong" $ do
      runRedisAction ping `shouldReturn` RespSimpleString "PONG"
    it "bulkSet is encoded properly and subsequent gets work properly" $ do
      runRedisAction (bulkSet [("a", "b"), ("c", "d"), ("e", "f")]) `shouldReturn` RespSimpleString "OK"
      runRedisAction (get "a") `shouldReturn` RespBulkString "b"
      runRedisAction (get "c") `shouldReturn` RespBulkString "d"
      runRedisAction (get "e") `shouldReturn` RespBulkString "f"
    it "mget is encoded properly and returns multiple values" $ do
      runRedisAction (set "mget:key1" "value1") `shouldReturn` RespSimpleString "OK"
      runRedisAction (set "mget:key2" "value2") `shouldReturn` RespSimpleString "OK"
      runRedisAction (mget ["mget:key1", "mget:key2", "mget:missing"]) `shouldReturn`
        RespArray [RespBulkString "value1", RespBulkString "value2", RespNullBilkString]
    it "del is encoded properly and deletes the key" $ do
      runRedisAction (set "testKey" "testValue") `shouldReturn` RespSimpleString "OK"
      runRedisAction (del ["testKey"]) `shouldReturn` RespInteger 1
      runRedisAction (get "testKey") `shouldReturn` RespNullBilkString
    it "exists is encoded properly and checks if the key exists" $ do
      runRedisAction (set "testKey" "testValue") `shouldReturn` RespSimpleString "OK"
      runRedisAction (exists ["testKey"]) `shouldReturn` RespInteger 1
      runRedisAction (del ["testKey"]) `shouldReturn` RespInteger 1
      runRedisAction (exists ["testKey"]) `shouldReturn` RespInteger 0
    it "incr is encoded properly and increments the key" $ do
      runRedisAction (set "counter" "0") `shouldReturn` RespSimpleString "OK"
      runRedisAction (incr "counter") `shouldReturn` RespInteger 1
      runRedisAction (get "counter") `shouldReturn` RespBulkString "1"
    it "decr is encoded properly and decrements the key" $ do
      runRedisAction (set "counter:down" "5") `shouldReturn` RespSimpleString "OK"
      runRedisAction (decr "counter:down") `shouldReturn` RespInteger 4
      runRedisAction (get "counter:down") `shouldReturn` RespBulkString "4"
    it "psetex sets value with expiry" $ do
      runRedisAction (psetex "psetex:key" 600 "value") `shouldReturn` RespSimpleString "OK"
      runRedisAction (get "psetex:key") `shouldReturn` RespBulkString "value"
    it "setnx is encoded properly and only sets when a key is missing" $ do
      runRedisAction (setnx "nx:key" "first") `shouldReturn` RespInteger 1
      runRedisAction (setnx "nx:key" "second") `shouldReturn` RespInteger 0
      runRedisAction (get "nx:key") `shouldReturn` RespBulkString "first"
    it "hset and hget are encoded properly and work correctly" $ do
      runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
      runRedisAction (hget "myhash" "field1") `shouldReturn` RespBulkString "value1"
    it "hmget returns multiple hash fields" $ do
      runRedisAction (hset "hash:multi" "field1" "value1") `shouldReturn` RespInteger 1
      runRedisAction (hset "hash:multi" "field2" "value2") `shouldReturn` RespInteger 1
      runRedisAction (hmget "hash:multi" ["field1", "field2", "missing"]) `shouldReturn`
        RespArray [RespBulkString "value1", RespBulkString "value2", RespNullBilkString]
    it "hexists indicates whether a hash field exists" $ do
      runRedisAction (hset "hash:exists" "field" "value") `shouldReturn` RespInteger 1
      runRedisAction (hexists "hash:exists" "field") `shouldReturn` RespInteger 1
      runRedisAction (hexists "hash:exists" "missing") `shouldReturn` RespInteger 0
    it "lpush and lrange are encoded properly and work correctly" $ do
      runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (lrange "mylist" 0 2) `shouldReturn` RespArray [RespBulkString "three", RespBulkString "two", RespBulkString "one"]
    it "expire and ttl are encoded properly and work correctly" $ do
      runRedisAction (set "mykey" "myvalue") `shouldReturn` RespSimpleString "OK"
      runRedisAction (expire "mykey" 10) `shouldReturn` RespInteger 1
      runRedisAction (ttl "mykey") `shouldReturn` RespInteger 10
    it "rpush and lpop are encoded properly and work correctly" $ do
      runRedisAction (rpush "mylist2" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (lpop "mylist2") `shouldReturn` RespBulkString "one"
    it "rpop is encoded properly and works correctly" $ do
      runRedisAction (rpush "mylist3" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (rpop "mylist3") `shouldReturn` RespBulkString "three"
    it "sadd and smembers are encoded properly and work correctly" $ do
      runRedisAction (sadd "myset" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (smembers "myset") `shouldReturn` RespArray [RespBulkString "one", RespBulkString "two", RespBulkString "three"]
    it "scard returns the set cardinality" $ do
      runRedisAction (sadd "size:set" ["a", "b", "c"]) `shouldReturn` RespInteger 3
      runRedisAction (scard "size:set") `shouldReturn` RespInteger 3
    it "sismember detects membership" $ do
      runRedisAction (sadd "member:set" ["alpha"]) `shouldReturn` RespInteger 1
      runRedisAction (sismember "member:set" "alpha") `shouldReturn` RespInteger 1
      runRedisAction (sismember "member:set" "beta") `shouldReturn` RespInteger 0
    it "hdel is encoded properly and works correctly" $ do
      runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
      runRedisAction (hdel "myhash" ["field1"]) `shouldReturn` RespInteger 1
      runRedisAction (hget "myhash" "field1") `shouldReturn` RespNullBilkString
    it "hkeys is encoded properly and works correctly" $ do
      runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
      runRedisAction (hset "myhash" "field2" "value2") `shouldReturn` RespInteger 1
      runRedisAction (hkeys "myhash") `shouldReturn` RespArray [RespBulkString "field1", RespBulkString "field2"]
    it "hvals is encoded properly and works correctly" $ do
      runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
      runRedisAction (hset "myhash" "field2" "value2") `shouldReturn` RespInteger 1
      runRedisAction (hvals "myhash") `shouldReturn` RespArray [RespBulkString "value1", RespBulkString "value2"]
    it "llen is encoded properly and works correctly" $ do
      runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (llen "mylist") `shouldReturn` RespInteger 3
    it "lindex is encoded properly and works correctly" $ do
      runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
      runRedisAction (lindex "mylist" 1) `shouldReturn` RespBulkString "two"
    it "zadd and zrange are encoded properly and work correctly" $ do
      runRedisAction (zadd "myzset" [(1, "one"), (2, "two"), (3, "three")]) `shouldReturn` RespInteger 3
      runRedisAction (zrange "myzset" 0 1 False) `shouldReturn` RespArray [RespBulkString "one", RespBulkString "two"]
      runRedisAction (zrange "myzset" 0 (-1) True)
        `shouldReturn` RespArray
          [ RespBulkString "one",
            RespBulkString "1",
            RespBulkString "two",
            RespBulkString "2",
            RespBulkString "three",
            RespBulkString "3"
          ]

  describe "Pipelining works: " $ do
    it "can pipeline 100 commands and retrieve their values" $ do
      runRedisAction
        ( do
            ClientState client _ <- State.get
            send client $ mconcat ([Builder.toLazyByteString . encode . RespArray $ map RespBulkString ["SET", "KEY" <> BSC.pack (show n), "VALUE" <> BSC.pack (show n)] | n <- [1 .. 100]])
            parseManyWith 100 (receive client)
        )
        `shouldReturn` replicate 100 (RespSimpleString "OK")
      runRedisAction
        ( do
            ClientState client _ <- State.get
            send client $ mconcat ([Builder.toLazyByteString . encode . RespArray $ map RespBulkString ["GET", "KEY" <> BSC.pack (show n)] | n <- [1 .. 100]])
            parseManyWith 100 (receive client)
        )
        `shouldReturn` [RespBulkString ("VALUE" <> BSC.pack (show n)) | n <- [1 .. 100]]
