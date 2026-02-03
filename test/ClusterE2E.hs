{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..), PlainTextClient (NotConnectedPlainTextClient))
import Cluster (NodeAddress (..), calculateSlot)
import ClusterCommandClient
import ConnectionPool (PoolConfig (..))
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import RedisCommandClient (RedisCommands (..))
import Resp (RespData (..))
import Test.Hspec

-- | Create a cluster client for testing
createTestClusterClient :: IO (ClusterClient PlainTextClient)
createTestClusterClient = do
  let config = ClusterConfig
        { clusterSeedNode = NodeAddress "localhost" 6379,
          clusterPoolConfig = PoolConfig
            { maxConnectionsPerNode = 1,
              connectionTimeout = 5000,
              maxRetries = 3,
              ConnectionPool.useTLS = False
            },
          clusterMaxRetries = 3,
          clusterRetryDelay = 100000,
          clusterTopologyRefreshInterval = 60
        }
  createClusterClient config connector
  where
    connector (NodeAddress host port) = do
      connect (NotConnectedPlainTextClient host (Just port))

-- | Execute a command against the cluster
runClusterCommand :: ClusterClient PlainTextClient -> String -> IO (Either ClusterError RespData) -> IO RespData
runClusterCommand client key action = do
  result <- action
  case result of
    Left err -> fail $ "Cluster error: " ++ show err
    Right val -> return val

main :: IO ()
main = hspec $ do
  describe "Cluster E2E Tests" $ do
    describe "Basic cluster operations" $ do
      it "can connect to cluster and query topology" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Just creating the client queries topology, so if we get here, it worked
          return ()

      it "can execute GET/SET commands on cluster" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          let key = "cluster:test:key"
          
          -- SET command
          setResult <- executeClusterCommand client (BS.pack key) (set key "testvalue") connector
          case setResult of
            Right (RespSimpleString "OK") -> return ()
            Right other -> expectationFailure $ "Unexpected SET response: " ++ show other
            Left err -> expectationFailure $ "SET failed: " ++ show err
          
          -- GET command
          getResult <- executeClusterCommand client (BS.pack key) (get key) connector
          case getResult of
            Right (RespBulkString "testvalue") -> return ()
            Right other -> expectationFailure $ "Unexpected GET response: " ++ show other
            Left err -> expectationFailure $ "GET failed: " ++ show err

      it "routes commands to correct nodes based on slot" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Test with multiple keys that should hash to different slots
          let keys = ["key1", "key2", "key3", "key4", "key5"]
          
          -- Set all keys
          mapM_ (\key -> do
            result <- executeClusterCommand client (BS.pack key) (set key ("value_" ++ key)) connector
            case result of
              Right (RespSimpleString "OK") -> return ()
              Right other -> expectationFailure $ "Unexpected SET response for " ++ key ++ ": " ++ show other
              Left err -> expectationFailure $ "SET failed for " ++ key ++ ": " ++ show err
            ) keys
          
          -- Get all keys and verify
          mapM_ (\key -> do
            result <- executeClusterCommand client (BS.pack key) (get key) connector
            case result of
              Right (RespBulkString val) | val == BSL.pack ("value_" ++ key) -> return ()
              Right other -> expectationFailure $ "Unexpected GET response for " ++ key ++ ": " ++ show other
              Left err -> expectationFailure $ "GET failed for " ++ key ++ ": " ++ show err
            ) keys

      it "handles keys with hash tags correctly" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- Keys with same hash tag should go to same slot
          let key1 = "{user:123}:profile"
              key2 = "{user:123}:settings"
          
          -- Both keys should hash to the same slot
          slot1 <- calculateSlot (BS.pack key1)
          slot2 <- calculateSlot (BS.pack key2)
          slot1 `shouldBe` slot2
          
          -- Set both keys
          result1 <- executeClusterCommand client (BS.pack key1) (set key1 "profile_data") connector
          result2 <- executeClusterCommand client (BS.pack key2) (set key2 "settings_data") connector
          
          case (result1, result2) of
            (Right (RespSimpleString "OK"), Right (RespSimpleString "OK")) -> return ()
            _ -> expectationFailure "Failed to set keys with hash tags"

      it "can execute multiple operations in sequence" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          let key = "counter:test"
          
          -- SET initial value
          setResult <- executeClusterCommand client (BS.pack key) (set key "0") connector
          case setResult of
            Right (RespSimpleString "OK") -> return ()
            _ -> expectationFailure "Failed to set initial counter value"
          
          -- INCR
          incrResult <- executeClusterCommand client (BS.pack key) (incr key) connector
          case incrResult of
            Right (RespInteger 1) -> return ()
            Right other -> expectationFailure $ "Unexpected INCR response: " ++ show other
            Left err -> expectationFailure $ "INCR failed: " ++ show err
          
          -- GET to verify
          getResult <- executeClusterCommand client (BS.pack key) (get key) connector
          case getResult of
            Right (RespBulkString "1") -> return ()
            Right other -> expectationFailure $ "Unexpected GET response: " ++ show other
            Left err -> expectationFailure $ "GET failed: " ++ show err

      it "can execute PING through cluster" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          -- PING doesn't need a key, so we use a dummy key for routing
          result <- executeClusterCommand client "dummy" ping connector
          case result of
            Right (RespSimpleString "PONG") -> return ()
            Right other -> expectationFailure $ "Unexpected PING response: " ++ show other
            Left err -> expectationFailure $ "PING failed: " ++ show err

      it "can query CLUSTER SLOTS" $ do
        bracket createTestClusterClient closeClusterClient $ \client -> do
          result <- executeClusterCommand client "dummy" clusterSlots connector
          case result of
            Right (RespArray slots) -> do
              -- Verify we got some slot ranges
              length slots `shouldSatisfy` (> 0)
            Right other -> expectationFailure $ "Unexpected CLUSTER SLOTS response: " ++ show other
            Left err -> expectationFailure $ "CLUSTER SLOTS failed: " ++ show err

  where
    connector (NodeAddress host port) = do
      connect (NotConnectedPlainTextClient host (Just port))
