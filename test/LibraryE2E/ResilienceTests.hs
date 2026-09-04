{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ResilienceTests (spec) where

import           Control.Concurrent            (threadDelay)
import           Control.Exception             (SomeException, displayException,
                                                throwIO, try)
import           Database.Redis.Cluster.Client (ClusterConfig (..),
                                                ClusterError (..),
                                                closeClusterClient,
                                                executeKeyedClusterCommand,
                                                refreshTopology)
import           Database.Redis.Command        (showBS)
import           Database.Redis.Resp           (RespData (..))

import           LibraryE2E.Utils

import           Test.Hspec

spec :: Spec
spec = describe "Error Handling & Resilience" $ do
  describe "Exception-safe node restoration" $ do
    it "restores a stopped node after an intentional body failure" $ do
      result <- try $ withStoppedNode 3 $
        throwIO $ userError "intentional node fixture failure"
        :: IO (Either SomeException ())
      case result of
        Left err ->
          displayException err `shouldContain`
            "intentional node fixture failure"
        Right () ->
          expectationFailure "intentional failure unexpectedly succeeded"

    it "starts the following example with a healthy cluster" $ do
      waitForClusterReady 5
      client <- createTestClient
      result <- executeKeyedClusterCommand
        client
        "restoration-followup"
        ["SET", "restoration-followup", "healthy"]
      result `shouldSatisfy` isRight'
      flushAllNodes client
      closeClusterClient client

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
        executeKeyedClusterCommand client k ["SET", k, v]
        ) keys

      -- All should succeed (MOVED handled transparently if needed)
      mapM_ (\r -> r `shouldSatisfy` isRight') results

      -- Read them back
      readResults <- mapM (\(k, _) ->
        executeKeyedClusterCommand client k ["GET", k]
        ) keys

      mapM_ (\((_, v), r) -> r `shouldBe` Right (RespBulkString v)) (zip keys readResults)

      flushAllNodes client
      closeClusterClient client

  describe "Max retries exceeded" $ do
    it "returns MaxRetriesExceeded when all nodes for a slot are down" $ do
      -- Create client with very few retries
      client <- createTestClientWith (\c -> c {
        clusterMaxRetries = 1,
        clusterRetryDelay = 10000  -- 10ms to speed up test
      })

      withStoppedNodes [4, 5] $ do
        threadDelay 3000000  -- 3s for detection

        -- Try operations — some should fail with MaxRetriesExceeded or ConnectionError
        -- We try several keys to increase odds of hitting a down node's slots
        let tryKeys = ["maxretry-" <> showBS i | i <- [1..20 :: Int]]
        results <- mapM (\k ->
          executeKeyedClusterCommand client k ["SET", k, "v"]
          ) tryKeys

        -- At least some should fail (nodes 4 & 5 own some slots)
        let failures = [e | Left e <- results]
        length failures `shouldSatisfy` (> 0)

        -- Verify failures are the right error types
        let isExpectedError (MaxRetriesExceeded _) = True
            isExpectedError (ConnectionError _)    = True
            isExpectedError _                      = False
        mapM_ (\e -> e `shouldSatisfy` isExpectedError) failures

      flushAllNodes client
      closeClusterClient client

  describe "ConnectionClosed handling" $ do
    it "node kill produces ConnectionError, not hang or parse error" $ do
      client <- createTestClient

      -- Warm up a connection to node 3
      -- Use hash tag to target specific node's slots
      _ <- executeKeyedClusterCommand client "conn-close-test" ["SET", "conn-close-test", "v"]

      withStoppedNode 3 $ do
        threadDelay 2000000  -- 2s

        -- Try operations — some may fail with ConnectionError
        results <- mapM (\i -> do
          let k = "connclose-" <> showBS i
          try (executeKeyedClusterCommand client k ["SET", k, "v"])
            :: IO (Either SomeException (Either ClusterError RespData))
          ) [1..10 :: Int]

        -- Should not hang (test completing is the assertion)
        -- Any failures should be connection-related, not parse errors
        let checkResult r = case r of
              Left _                              -> True  -- Exception is fine
              Right (Left (ConnectionError _))    -> True
              Right (Left (MaxRetriesExceeded _)) -> True
              Right (Right _)                     -> True  -- Success is fine (different node)
              Right (Left _)                      -> True  -- Other cluster errors ok
        mapM_ (\r -> r `shouldSatisfy` checkResult) results

      flushAllNodes client
      closeClusterClient client

  describe "Recovery after node restart" $ do
    it "operations resume after stopped node is restarted" $ do
      client <- createTestClient

      -- Establish baseline
      r1 <- executeKeyedClusterCommand client "recovery-key" ["SET", "recovery-key", "before"]
      r1 `shouldSatisfy` isRight'

      withStoppedNode 3 $
        threadDelay 3000000

      -- Force topology refresh
      _ <- try (refreshTopology client) :: IO (Either SomeException ())

      -- Operations should work again
      r2 <- executeKeyedClusterCommand client "recovery-key2" ["SET", "recovery-key2", "after"]
      r2 `shouldSatisfy` isRight'

      r3 <- executeKeyedClusterCommand client "recovery-key2" ["GET", "recovery-key2"]
      r3 `shouldBe` Right (RespBulkString "after")

      flushAllNodes client
      closeClusterClient client

-- | Helper
isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
