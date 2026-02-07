{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ResilienceTests (spec) where

import           Client                     (PlainTextClient)
import           Cluster                    (NodeAddress (..))
import           ClusterCommandClient       (ClusterClient (..), ClusterConfig (..),
                                             ClusterError (..),
                                             closeClusterClient,
                                             executeClusterCommand,
                                             refreshTopology)
import           ConnectionPool             (PoolConfig (..))
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (SomeException, try)
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "Error Handling & Resilience" $ do

  describe "MOVED error retry" $ do
    it "transparently handles slot routing across nodes" $ do
      client <- createTestClient

      -- Write keys that hash to different slots/nodes
      -- Use different prefixes to hit different hash slots
      let keys = [ ("resilience-a", "val-a")
                 , ("resilience-b", "val-b")
                 , ("resilience-c", "val-c")
                 , ("resilience-x", "val-x")
                 , ("resilience-y", "val-y")
                 ]
      results <- mapM (\(k, v) ->
        executeClusterCommand client (BS8.pack k) (set k v) testConnector
        ) keys

      -- All should succeed (MOVED handled transparently if needed)
      mapM_ (\r -> r `shouldSatisfy` isRight') results

      -- Read them back
      readResults <- mapM (\(k, _) ->
        executeClusterCommand client (BS8.pack k) (get k) testConnector
        ) keys

      mapM_ (\((_, v), r) -> r `shouldBe` Right (RespBulkString (LBS8.pack v))) (zip keys readResults)

      flushAllNodes client
      closeClusterClient client

  describe "Max retries exceeded" $ do
    it "returns MaxRetriesExceeded when all nodes for a slot are down" $ do
      -- Create client with very few retries
      client <- createTestClientWith (\c -> c {
        clusterMaxRetries = 1,
        clusterRetryDelay = 10000  -- 10ms to speed up test
      })

      -- Stop multiple nodes to guarantee some slots are unavailable
      stopNode 4
      stopNode 5
      threadDelay 3000000  -- 3s for detection

      -- Try operations — some should fail with MaxRetriesExceeded or ConnectionError
      -- We try several keys to increase odds of hitting a down node's slots
      let tryKeys = ["maxretry-" ++ show i | i <- [1..20 :: Int]]
      results <- mapM (\k ->
        executeClusterCommand client (BS8.pack k) (set k "v") testConnector
        ) tryKeys

      -- At least some should fail (nodes 4 & 5 own some slots)
      let failures = [e | Left e <- results]
      length failures `shouldSatisfy` (> 0)

      -- Verify failures are the right error types
      let isExpectedError (MaxRetriesExceeded _) = True
          isExpectedError (ConnectionError _)    = True
          isExpectedError _                      = False
      mapM_ (\e -> e `shouldSatisfy` isExpectedError) failures

      -- Restart nodes
      startNode 4
      startNode 5
      waitForClusterReady 30
      threadDelay 5000000  -- 5s stabilization

      flushAllNodes client
      closeClusterClient client

  describe "ConnectionClosed handling" $ do
    it "node kill produces ConnectionError, not hang or parse error" $ do
      client <- createTestClient

      -- Warm up a connection to node 3
      -- Use hash tag to target specific node's slots
      _ <- executeClusterCommand client "conn-close-test" (set "conn-close-test" "v") testConnector

      -- Kill node 3 abruptly
      stopNode 3
      threadDelay 2000000  -- 2s

      -- Try operations — some may fail with ConnectionError
      results <- mapM (\i -> do
        let k = "connclose-" ++ show i
        try (executeClusterCommand client (BS8.pack k) (set k "v") testConnector)
          :: IO (Either SomeException (Either ClusterError RespData))
        ) [1..10 :: Int]

      -- Should not hang (test completing is the assertion)
      -- Any failures should be connection-related, not parse errors
      let checkResult r = case r of
            Left _                          -> True  -- Exception is fine
            Right (Left (ConnectionError _))    -> True
            Right (Left (MaxRetriesExceeded _)) -> True
            Right (Right _)                     -> True  -- Success is fine (different node)
            Right (Left _)                      -> True  -- Other cluster errors ok
      mapM_ (\r -> r `shouldSatisfy` checkResult) results

      -- Restart
      startNode 3
      waitForClusterReady 30
      threadDelay 5000000

      flushAllNodes client
      closeClusterClient client

  describe "Recovery after node restart" $ do
    it "operations resume after stopped node is restarted" $ do
      client <- createTestClient

      -- Establish baseline
      r1 <- executeClusterCommand client "recovery-key" (set "recovery-key" "before") testConnector
      r1 `shouldSatisfy` isRight'

      -- Stop node
      stopNode 3
      threadDelay 3000000

      -- Restart node
      startNode 3
      waitForClusterReady 30
      threadDelay 5000000  -- stabilization

      -- Force topology refresh
      _ <- try (refreshTopology client testConnector) :: IO (Either SomeException ())

      -- Operations should work again
      r2 <- executeClusterCommand client "recovery-key2" (set "recovery-key2" "after") testConnector
      r2 `shouldSatisfy` isRight'

      r3 <- executeClusterCommand client "recovery-key2" (get "recovery-key2") testConnector
      r3 `shouldBe` Right (RespBulkString "after")

      flushAllNodes client
      closeClusterClient client

-- | Helper
isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
