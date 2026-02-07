{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Basic (spec) where

import           Cluster                    (calculateSlot)
import           ClusterCommandClient       (closeClusterClient)
import           ClusterE2E.Utils
import           Control.Exception          (bracket)
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy.Char8 as BSL
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))
import           Test.Hspec

spec :: Spec
spec = describe "Basic cluster operations" $ do
    it "can connect to cluster and query topology" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Just creating the client queries topology, so if we get here, it worked
        return ()

    it "can execute GET/SET commands on cluster" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        let key = "cluster:test:key"

        -- SET command
        setResult <- runCmd client $ set key "testvalue"
        case setResult of
          RespSimpleString "OK" -> return ()
          other -> expectationFailure $ "Unexpected SET response: " ++ show other

        -- GET command
        getResult <- runCmd client $ get key
        case getResult of
          RespBulkString "testvalue" -> return ()
          other -> expectationFailure $ "Unexpected GET response: " ++ show other

    it "routes commands to correct nodes based on slot" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Test with multiple keys that should hash to different slots
        let keys = ["key1", "key2", "key3", "key4", "key5"]

        -- Set all keys
        mapM_ (\key -> do
          result <- runCmd client $ set key ("value_" ++ key)
          case result of
            RespSimpleString "OK" -> return ()
            other -> expectationFailure $ "Unexpected SET response for " ++ key ++ ": " ++ show other
          ) keys

        -- Get all keys and verify
        mapM_ (\key -> do
          result <- runCmd client $ get key
          case result of
            RespBulkString val | val == BSL.pack ("value_" ++ key) -> return ()
            other -> expectationFailure $ "Unexpected GET response for " ++ key ++ ": " ++ show other
          ) keys

    it "handles keys with hash tags correctly" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- Keys with same hash tag should go to same slot
        let key1 = "{user:123}:profile"
            key2 = "{user:123}:settings"

        -- Both keys should hash to the same slot
        slot1 <- calculateSlot (BSC.pack key1)
        slot2 <- calculateSlot (BSC.pack key2)
        slot1 `shouldBe` slot2

        -- Set both keys
        result1 <- runCmd client $ set key1 "profile_data"
        result2 <- runCmd client $ set key2 "settings_data"

        case (result1, result2) of
          (RespSimpleString "OK", RespSimpleString "OK") -> return ()
          _ -> expectationFailure "Failed to set keys with hash tags"

    it "can execute multiple operations in sequence" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        let key = "counter:test"

        -- SET initial value
        setResult <- runCmd client $ set key "0"
        case setResult of
          RespSimpleString "OK" -> return ()
          _ -> expectationFailure "Failed to set initial counter value"

        -- INCR
        incrResult <- runCmd client $ incr key
        case incrResult of
          RespInteger 1 -> return ()
          other -> expectationFailure $ "Unexpected INCR response: " ++ show other

        -- GET to verify
        getResult <- runCmd client $ get key
        case getResult of
          RespBulkString "1" -> return ()
          other -> expectationFailure $ "Unexpected GET response: " ++ show other

    it "can execute PING through cluster" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        -- PING doesn't need a routing key - the RedisCommands instance handles it
        result <- runCmd client ping
        case result of
          RespSimpleString "PONG" -> return ()
          other -> expectationFailure $ "Unexpected PING response: " ++ show other

    it "can query CLUSTER SLOTS" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        result <- runCmd client clusterSlots
        case result of
          RespArray slots -> do
            -- Verify we got some slot ranges
            length slots `shouldSatisfy` (> 0)
          other -> expectationFailure $ "Unexpected CLUSTER SLOTS response: " ++ show other

    it "returns WRONGTYPE error for wrong command on key type" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        _ <- runCmd client $ set "cluster:wrongtype" "value"
        result <- runCmd client $ lpush "cluster:wrongtype" ["item"]
        case result of
          RespError err -> err `shouldContain` "WRONGTYPE"
          other -> expectationFailure $ "Expected WRONGTYPE error, got: " ++ show other

    it "DEL removes keys in cluster" $ do
      bracket createTestClusterClient closeClusterClient $ \client -> do
        _ <- runCmd client $ set "cluster:deltest" "value"
        getResult <- runCmd client $ get "cluster:deltest"
        getResult `shouldBe` RespBulkString "value"
        _ <- runCmd client $ del ["cluster:deltest"]
        afterDel <- runCmd client $ get "cluster:deltest"
        afterDel `shouldBe` RespNullBulkString
