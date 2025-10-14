{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient)
import Control.Monad (void)
import Control.Monad.State qualified as State
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as BSC
import RedisCommandClient
  ( ClientState (..),
    GeoRadiusFlag (..),
    GeoSearchBy (..),
    GeoSearchFrom (..),
    GeoSearchOption (..),
    GeoUnit (..),
    RedisCommandClient,
    RedisCommands (..),
    RunState (..),
    parseManyWith,
    runCommandsAgainstPlaintextHost
  )
import Resp
  ( Encodable (encode),
    RespData (..),
  )
import Test.Hspec (before_, describe, expectationFailure, hspec, it, shouldBe, shouldReturn, shouldSatisfy)

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
    it "auth negotiates the RESP3 handshake" $ do
      authResp <- runRedisAction (auth "")
      case authResp of
        RespError err -> expectationFailure $ "Unexpected AUTH error: " <> err
        RespMap _ -> pure ()
        RespArray _ -> pure ()
        RespSimpleString "OK" -> pure ()
        _ -> expectationFailure $ "Unexpected AUTH response shape: " <> show authResp
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
    it "dbsize reflects the number of keys" $ do
      runRedisAction dbsize `shouldReturn` RespInteger 0
      runRedisAction (set "dbsize:key" "value") `shouldReturn` RespSimpleString "OK"
      runRedisAction dbsize `shouldReturn` RespInteger 1
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
    it "clientSetInfo updates client metadata" $ do
      runRedisAction (clientSetInfo ["LIB-NAME", "redis-client-e2e"]) `shouldReturn` RespSimpleString "OK"
      runRedisAction (clientSetInfo ["LIB-VER", "0.1-test"]) `shouldReturn` RespSimpleString "OK"
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

    it "geoadd and geodist work correctly" $ do
      runRedisAction (geoadd "geo:italy" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      runRedisAction (geodist "geo:italy" "Palermo" "Catania" (Just Kilometers)) `shouldReturn` RespBulkString "166.2742"

    it "geohash returns geohash strings for members" $ do
      runRedisAction (geoadd "geo:hash" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      runRedisAction (geohash "geo:hash" ["Palermo", "Catania"]) `shouldReturn`
        RespArray [RespBulkString "sqc8b49rny0", RespBulkString "sqdtr74hyu0"]

    it "geopos returns longitudes and latitudes" $ do
      runRedisAction (geoadd "geo:pos" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      response <- runRedisAction (geopos "geo:pos" ["Palermo", "Catania"])
      case response of
        RespArray [RespArray [RespBulkString lon1, RespBulkString lat1], RespArray [RespBulkString lon2, RespBulkString lat2]] -> do
          lon1 `shouldSatisfy` (BSC.isPrefixOf "13.36")
          lat1 `shouldSatisfy` (BSC.isPrefixOf "38.11")
          lon2 `shouldSatisfy` (BSC.isPrefixOf "15.08")
          lat2 `shouldSatisfy` (BSC.isPrefixOf "37.50")
        _ -> expectationFailure $ "Unexpected GEOPOS response: " <> show response

    it "georadius returns members ordered with distances" $ do
      runRedisAction (geoadd "geo:radius" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      radiusResult <- runRedisAction (georadius "geo:radius" 15 37 200 Kilometers [GeoWithDist, GeoRadiusAsc])
      case radiusResult of
        RespArray [RespArray [RespBulkString "Catania", RespBulkString dist1], RespArray [RespBulkString "Palermo", RespBulkString dist2]] -> do
          dist1 `shouldSatisfy` (not . BSC.null)
          dist2 `shouldSatisfy` (not . BSC.null)
        _ -> expectationFailure $ "Unexpected GEORADIUS response: " <> show radiusResult

    it "georadiusRo reads data with distance flags" $ do
      runRedisAction (geoadd "geo:radius-ro" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      roResult <- runRedisAction (georadiusRo "geo:radius-ro" 15 37 200 Kilometers [GeoWithDist, GeoRadiusAsc])
      case roResult of
        RespArray [RespArray [RespBulkString "Catania", RespBulkString dist1], RespArray [RespBulkString "Palermo", RespBulkString dist2]] -> do
          dist1 `shouldSatisfy` (not . BSC.null)
          dist2 `shouldSatisfy` (not . BSC.null)
        _ -> expectationFailure $ "Unexpected GEORADIUS_RO response: " <> show roResult

    it "georadiusByMember returns nearby members" $ do
      runRedisAction (geoadd "geo:member" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      byMember <- runRedisAction (georadiusByMember "geo:member" "Palermo" 200 Kilometers [GeoWithDist, GeoRadiusAsc])
      case byMember of
        RespArray [RespArray [RespBulkString "Palermo"], RespArray [RespBulkString "Catania", RespBulkString dist]] -> do
          dist `shouldSatisfy` (not . BSC.null)
        RespArray [RespArray [RespBulkString "Palermo", RespBulkString distSelf], RespArray [RespBulkString "Catania", RespBulkString distOther]] -> do
          distSelf `shouldSatisfy` (not . BSC.null)
          distOther `shouldSatisfy` (not . BSC.null)
        _ -> expectationFailure $ "Unexpected GEORADIUSBYMEMBER response: " <> show byMember

    it "georadiusByMemberRo reads without mutating state" $ do
      runRedisAction (geoadd "geo:member-ro" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      byMemberRo <- runRedisAction (georadiusByMemberRo "geo:member-ro" "Palermo" 200 Kilometers [GeoWithDist, GeoRadiusAsc])
      case byMemberRo of
        RespArray [RespArray [RespBulkString "Palermo"], RespArray [RespBulkString "Catania", RespBulkString dist]] -> do
          dist `shouldSatisfy` (not . BSC.null)
        RespArray [RespArray [RespBulkString "Palermo", RespBulkString distSelf], RespArray [RespBulkString "Catania", RespBulkString distOther]] -> do
          distSelf `shouldSatisfy` (not . BSC.null)
          distOther `shouldSatisfy` (not . BSC.null)
        _ -> expectationFailure $ "Unexpected GEORADIUSBYMEMBER_RO response: " <> show byMemberRo

    it "geosearch and geosearchstore integrate with sorted sets" $ do
      runRedisAction (geoadd "geo:search" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
      runRedisAction (geosearch "geo:search" (GeoFromLonLat 15 37) (GeoByRadius 200 Kilometers) [GeoSearchAsc])
        `shouldReturn` RespArray [RespBulkString "Catania", RespBulkString "Palermo"]
      runRedisAction (geosearchstore "geo:dest" "geo:search" (GeoFromLonLat 15 37) (GeoByRadius 200 Kilometers) [GeoSearchAsc] True)
        `shouldReturn` RespInteger 2
      storeResult <- runRedisAction (zrange "geo:dest" 0 (-1) True)
      case storeResult of
        RespArray [RespBulkString member1, _, RespBulkString member2, _] -> do
          member1 `shouldBe` "Catania"
          member2 `shouldBe` "Palermo"
        _ -> expectationFailure $ "Unexpected GEOSEARCHSTORE ZRANGE response: " <> show storeResult

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
