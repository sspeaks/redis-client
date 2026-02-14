{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.StandaloneTests (spec) where

import           Cluster                  (NodeAddress (..))
import           Database.Redis.Command   (RedisCommands (..))
import           Database.Redis.Connector (clusterPlaintextConnector)
import           Database.Redis.Resp      (RespData (..))
import           StandaloneClient         (StandaloneClient,
                                           closeStandaloneClient,
                                           createStandaloneClient,
                                           runStandaloneClient)

import           Test.Hspec

-- | Standalone Redis node address (standalone container in docker-cluster)
standaloneNode :: NodeAddress
standaloneNode = NodeAddress "redis-standalone.local" 6390

-- | Create a standalone multiplexed client for testing
createTestStandaloneClient :: IO StandaloneClient
createTestStandaloneClient =
  createStandaloneClient clusterPlaintextConnector standaloneNode

spec :: Spec
spec = describe "Standalone Multiplexed Client" $ do

  describe "Basic operations" $ do
    it "SET and GET round-trip" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ set "standalone-key1" "value1"
      result <- runStandaloneClient client $ get "standalone-key1"
      result `shouldBe` RespBulkString "value1"
      _ <- runStandaloneClient client $ del ["standalone-key1"]
      closeStandaloneClient client

    it "GET returns Null for missing key" $ do
      client <- createTestStandaloneClient
      result <- runStandaloneClient client $ get "nonexistent-standalone-key"
      result `shouldBe` RespNullBulkString
      closeStandaloneClient client

    it "DEL removes keys and returns count" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ set "del-key1" "v1"
      _ <- runStandaloneClient client $ set "del-key2" "v2"
      result <- runStandaloneClient client $ del ["del-key1", "del-key2"]
      result `shouldBe` RespInteger 2
      -- Verify keys are gone
      r1 <- runStandaloneClient client $ get "del-key1"
      r1 `shouldBe` RespNullBulkString
      closeStandaloneClient client

    it "MGET returns multiple values" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ set "mget-k1" "v1"
      _ <- runStandaloneClient client $ set "mget-k2" "v2"
      result <- runStandaloneClient client $ mget ["mget-k1", "mget-k2", "mget-missing"]
      result `shouldBe` RespArray [RespBulkString "v1", RespBulkString "v2", RespNullBulkString]
      _ <- runStandaloneClient client $ del ["mget-k1", "mget-k2"]
      closeStandaloneClient client

    it "SET returns OK" $ do
      client <- createTestStandaloneClient
      result <- runStandaloneClient client $ set "set-ok-key" "val"
      result `shouldBe` RespSimpleString "OK"
      _ <- runStandaloneClient client $ del ["set-ok-key"]
      closeStandaloneClient client

  describe "Hash commands" $ do
    it "HSET, HGET, and HDEL" $ do
      client <- createTestStandaloneClient
      -- HSET returns number of fields added
      r1 <- runStandaloneClient client $ hset "myhash" "field1" "value1"
      r1 `shouldBe` RespInteger 1
      -- HGET returns the value
      r2 <- runStandaloneClient client $ hget "myhash" "field1"
      r2 `shouldBe` RespBulkString "value1"
      -- HDEL returns number of fields removed
      r3 <- runStandaloneClient client $ hdel "myhash" ["field1"]
      r3 `shouldBe` RespInteger 1
      -- HGET after delete returns Null
      r4 <- runStandaloneClient client $ hget "myhash" "field1"
      r4 `shouldBe` RespNullBulkString
      _ <- runStandaloneClient client $ del ["myhash"]
      closeStandaloneClient client

    it "HMGET returns multiple hash fields" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ hset "hmget-hash" "f1" "v1"
      _ <- runStandaloneClient client $ hset "hmget-hash" "f2" "v2"
      result <- runStandaloneClient client $ hmget "hmget-hash" ["f1", "f2", "f3"]
      result `shouldBe` RespArray [RespBulkString "v1", RespBulkString "v2", RespNullBulkString]
      _ <- runStandaloneClient client $ del ["hmget-hash"]
      closeStandaloneClient client

    it "HEXISTS checks field existence" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ hset "hexists-hash" "field" "val"
      r1 <- runStandaloneClient client $ hexists "hexists-hash" "field"
      r1 `shouldBe` RespInteger 1
      r2 <- runStandaloneClient client $ hexists "hexists-hash" "nofield"
      r2 `shouldBe` RespInteger 0
      _ <- runStandaloneClient client $ del ["hexists-hash"]
      closeStandaloneClient client

  describe "List commands" $ do
    it "LPUSH, RPUSH, and LRANGE" $ do
      client <- createTestStandaloneClient
      -- LPUSH returns list length
      r1 <- runStandaloneClient client $ lpush "mylist" ["c", "b", "a"]
      r1 `shouldBe` RespInteger 3
      -- RPUSH appends to tail
      r2 <- runStandaloneClient client $ rpush "mylist" ["d", "e"]
      r2 `shouldBe` RespInteger 5
      -- LRANGE returns elements in order
      r3 <- runStandaloneClient client $ lrange "mylist" 0 (-1)
      r3 `shouldBe` RespArray
        [ RespBulkString "a"
        , RespBulkString "b"
        , RespBulkString "c"
        , RespBulkString "d"
        , RespBulkString "e"
        ]
      _ <- runStandaloneClient client $ del ["mylist"]
      closeStandaloneClient client

    it "LLEN returns list length" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ lpush "llen-list" ["a", "b", "c"]
      result <- runStandaloneClient client $ llen "llen-list"
      result `shouldBe` RespInteger 3
      _ <- runStandaloneClient client $ del ["llen-list"]
      closeStandaloneClient client

    it "LPOP and RPOP" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ rpush "pop-list" ["a", "b", "c"]
      r1 <- runStandaloneClient client $ lpop "pop-list"
      r1 `shouldBe` RespBulkString "a"
      r2 <- runStandaloneClient client $ rpop "pop-list"
      r2 `shouldBe` RespBulkString "c"
      _ <- runStandaloneClient client $ del ["pop-list"]
      closeStandaloneClient client

  describe "Set commands" $ do
    it "SADD and SMEMBERS" $ do
      client <- createTestStandaloneClient
      -- SADD returns number of new members added
      r1 <- runStandaloneClient client $ sadd "myset" ["a", "b", "c"]
      r1 `shouldBe` RespInteger 3
      -- SADD duplicate returns 0
      r2 <- runStandaloneClient client $ sadd "myset" ["a"]
      r2 `shouldBe` RespInteger 0
      -- SMEMBERS returns all members (order may vary)
      r3 <- runStandaloneClient client $ smembers "myset"
      case r3 of
        RespArray members -> do
          length members `shouldBe` 3
          members `shouldSatisfy` (elem (RespBulkString "a"))
          members `shouldSatisfy` (elem (RespBulkString "b"))
          members `shouldSatisfy` (elem (RespBulkString "c"))
        _ -> expectationFailure $ "Expected RespArray, got: " ++ show r3
      _ <- runStandaloneClient client $ del ["myset"]
      closeStandaloneClient client

    it "SCARD returns set cardinality" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ sadd "scard-set" ["x", "y", "z"]
      result <- runStandaloneClient client $ scard "scard-set"
      result `shouldBe` RespInteger 3
      _ <- runStandaloneClient client $ del ["scard-set"]
      closeStandaloneClient client

    it "SISMEMBER checks membership" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ sadd "sismember-set" ["a", "b"]
      r1 <- runStandaloneClient client $ sismember "sismember-set" "a"
      r1 `shouldBe` RespInteger 1
      r2 <- runStandaloneClient client $ sismember "sismember-set" "z"
      r2 `shouldBe` RespInteger 0
      _ <- runStandaloneClient client $ del ["sismember-set"]
      closeStandaloneClient client

  describe "Sorted set commands" $ do
    it "ZADD and ZRANGE" $ do
      client <- createTestStandaloneClient
      -- ZADD returns number of elements added
      r1 <- runStandaloneClient client $ zadd "myzset"
        [(1, "alice"), (2, "bob"), (3, "charlie")]
      r1 `shouldBe` RespInteger 3
      -- ZRANGE returns elements sorted by score
      r2 <- runStandaloneClient client $ zrange "myzset" 0 (-1) False
      r2 `shouldBe` RespArray
        [ RespBulkString "alice"
        , RespBulkString "bob"
        , RespBulkString "charlie"
        ]
      _ <- runStandaloneClient client $ del ["myzset"]
      closeStandaloneClient client

    it "ZRANGE WITHSCORES returns scores interleaved" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ zadd "zrange-ws"
        [(10, "x"), (20, "y")]
      result <- runStandaloneClient client $ zrange "zrange-ws" 0 (-1) True
      result `shouldBe` RespArray
        [ RespBulkString "x"
        , RespBulkString "10"
        , RespBulkString "y"
        , RespBulkString "20"
        ]
      _ <- runStandaloneClient client $ del ["zrange-ws"]
      closeStandaloneClient client

  describe "Miscellaneous commands" $ do
    it "PING returns PONG" $ do
      client <- createTestStandaloneClient
      result <- runStandaloneClient client ping
      result `shouldBe` RespSimpleString "PONG"
      closeStandaloneClient client

    it "EXISTS checks key existence" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ set "exists-key" "val"
      r1 <- runStandaloneClient client $ exists ["exists-key"]
      r1 `shouldBe` RespInteger 1
      r2 <- runStandaloneClient client $ exists ["no-such-key"]
      r2 `shouldBe` RespInteger 0
      _ <- runStandaloneClient client $ del ["exists-key"]
      closeStandaloneClient client

    it "INCR and DECR" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client $ set "counter" "10"
      r1 <- runStandaloneClient client $ incr "counter"
      r1 `shouldBe` RespInteger 11
      r2 <- runStandaloneClient client $ decr "counter"
      r2 `shouldBe` RespInteger 10
      _ <- runStandaloneClient client $ del ["counter"]
      closeStandaloneClient client

    it "DBSIZE returns key count" $ do
      client <- createTestStandaloneClient
      _ <- runStandaloneClient client flushAll
      _ <- runStandaloneClient client $ set "db-k1" "v1"
      _ <- runStandaloneClient client $ set "db-k2" "v2"
      result <- runStandaloneClient client dbsize
      result `shouldBe` RespInteger 2
      _ <- runStandaloneClient client flushAll
      closeStandaloneClient client
