{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.ResilienceTests (spec) where

import           Control.Exception             (SomeException, displayException,
                                                throwIO, try)
import           Data.ByteString               (ByteString)
import           Database.Redis.Client         (PlainTextClient)
import           Database.Redis.Cluster.Client (ClusterClient,
                                                ClusterError (..),
                                                closeClusterClient,
                                                executeKeyedClusterCommand,
                                                refreshTopology)
import           Database.Redis.Resp           (RespData (..))
import           System.Timeout                (timeout)

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
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 3
      refreshTopology client
      assertRoundTrip client (stoppedNodeKey scenario) "restored-target"
      assertRoundTrip client (healthyNodeKey scenario) "restored-healthy"
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
    it "exhausts retries only for the stopped node's slot" $ do
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 4
      assertRoundTrip client (stoppedNodeKey scenario) "target-before"
      assertRoundTrip client (healthyNodeKey scenario) "healthy-before"

      withStoppedNode 4 $ do
        assertBoundedOutage client $ stoppedNodeKey scenario
        assertRoundTrip client (healthyNodeKey scenario) "healthy-during"

      refreshTopology client
      assertRoundTrip client (stoppedNodeKey scenario) "target-after"
      flushAllNodes client
      closeClusterClient client

  describe "ConnectionClosed handling" $ do
    it "turns a closed stopped-node connection into bounded retry exhaustion" $ do
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 3
      assertRoundTrip client (stoppedNodeKey scenario) "target-before"
      assertRoundTrip client (healthyNodeKey scenario) "healthy-before"

      withStoppedNode 3 $ do
        assertBoundedOutage client $ stoppedNodeKey scenario
        assertRoundTrip client (healthyNodeKey scenario) "healthy-during"

      refreshTopology client
      assertRoundTrip client (stoppedNodeKey scenario) "target-after"
      flushAllNodes client
      closeClusterClient client

  describe "Recovery after node restart" $ do
    it "restores the same stopped-node slot after refresh" $ do
      client <- createOutageTestClient
      scenario <- nodeOutageScenario client 3
      let targetKey = stoppedNodeKey scenario
          healthyKey = healthyNodeKey scenario

      assertRoundTrip client targetKey "target-before"
      assertRoundTrip client healthyKey "healthy-before"

      withStoppedNode 3 $ do
        assertBoundedOutage client targetKey
        assertRoundTrip client healthyKey "healthy-during"

      refreshTopology client
      assertRoundTrip client targetKey "target-after"

      flushAllNodes client
      closeClusterClient client

assertRoundTrip
  :: ClusterClient PlainTextClient
  -> ByteString
  -> ByteString
  -> Expectation
assertRoundTrip client key value = do
  result <- timeout 10000000 $ do
    setResult <- executeKeyedClusterCommand client key ["SET", key, value]
    getResult <- executeKeyedClusterCommand client key ["GET", key]
    return (setResult, getResult)
  case result of
    Nothing ->
      expectationFailure "Key round trip exceeded the 10-second bound"
    Just (setResult, getResult) -> do
      setResult `shouldBe` Right (RespSimpleString "OK")
      getResult `shouldBe` Right (RespBulkString value)

assertBoundedOutage
  :: ClusterClient PlainTextClient
  -> ByteString
  -> Expectation
assertBoundedOutage client key = do
  result <- timeout 10000000 $
    executeKeyedClusterCommand client key ["SET", key, "during-outage"]
  case result of
    Nothing ->
      expectationFailure "Stopped-node command exceeded the 10-second bound"
    Just (Left (MaxRetriesExceeded _)) ->
      return ()
    Just other ->
      expectationFailure $ "Expected MaxRetriesExceeded for stopped-node slot, got "
        ++ show other

-- | Helper
isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
