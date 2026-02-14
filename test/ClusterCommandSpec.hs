{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Cluster              (NodeAddress (..))
import           ClusterCommandClient
import           ConnectionPool       (PoolConfig (..))
import           Resp                 (RespData (..))
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Redirection error parsing" $ do
    describe "MOVED error parsing" $ do
      it "parses valid MOVED error" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 6381)

      it "parses MOVED error with different slot" $ do
        let result = parseRedirectionError "MOVED" "MOVED 12345 192.168.1.100:7000"
        result `shouldBe` Just (RedirectionInfo 12345 "192.168.1.100" 7000)

      it "handles MOVED error with hostname containing colons" $ do
        -- IPv6 addresses would need special handling
        -- For now, test that we handle hostnames correctly
        let result = parseRedirectionError "MOVED" "MOVED 3999 redis-node-1.example.com:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "redis-node-1.example.com" 6381)

      it "returns Nothing for malformed MOVED error" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with invalid slot" $ do
        let result = parseRedirectionError "MOVED" "MOVED notanumber 127.0.0.1:6381"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with invalid port" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:notaport"
        result `shouldBe` Nothing

      it "returns Nothing for MOVED with missing colon" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.16381"
        result `shouldBe` Nothing

    describe "ASK error parsing" $ do
      it "parses valid ASK error" $ do
        let result = parseRedirectionError "ASK" "ASK 3999 127.0.0.1:6381"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 6381)

      it "parses ASK error with different slot" $ do
        let result = parseRedirectionError "ASK" "ASK 8765 10.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 8765 "10.0.0.1" 6379)

      it "returns Nothing for malformed ASK error" $ do
        let result = parseRedirectionError "ASK" "ASK 3999"
        result `shouldBe` Nothing

      it "returns Nothing for wrong error type prefix" $ do
        let result = parseRedirectionError "ASK" "MOVED 3999 127.0.0.1:6381"
        result `shouldBe` Nothing

    describe "Edge cases" $ do
      it "handles slot 0" $ do
        let result = parseRedirectionError "MOVED" "MOVED 0 127.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 0 "127.0.0.1" 6379)

      it "handles slot 16383 (max)" $ do
        let result = parseRedirectionError "MOVED" "MOVED 16383 127.0.0.1:6379"
        result `shouldBe` Just (RedirectionInfo 16383 "127.0.0.1" 6379)

      it "handles high port numbers" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:65535"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 65535)

      it "handles hostname instead of IP" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 redis-node-1:6379"
        result `shouldBe` Just (RedirectionInfo 3999 "redis-node-1" 6379)

      it "returns Nothing for extra whitespace" $ do
        let result = parseRedirectionError "MOVED" "MOVED  3999  127.0.0.1:6381  "
        -- Tighter parsing rejects non-standard formatting (Redis never produces this)
        result `shouldBe` Nothing

      it "handles port 0" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:0"
        result `shouldBe` Just (RedirectionInfo 3999 "127.0.0.1" 0)

      it "returns Nothing for extra fields after host:port" $ do
        let result = parseRedirectionError "MOVED" "MOVED 3999 127.0.0.1:6381 extra-data"
        -- Tighter parsing rejects trailing data (Redis never produces this)
        result `shouldBe` Nothing

  describe "detectRedirection (byte-level fast path)" $ do
    it "returns Nothing for non-error responses (RespBulkString)" $ do
      detectRedirection (RespBulkString "OK") `shouldBe` Nothing

    it "returns Nothing for non-error responses (RespSimpleString)" $ do
      detectRedirection (RespSimpleString "OK") `shouldBe` Nothing

    it "returns Nothing for non-error responses (RespInteger)" $ do
      detectRedirection (RespInteger 42) `shouldBe` Nothing

    it "returns Nothing for non-redirect errors" $ do
      detectRedirection (RespError "ERR unknown command") `shouldBe` Nothing

    it "returns Nothing for short error messages" $ do
      detectRedirection (RespError "ERR") `shouldBe` Nothing

    it "returns Nothing for empty error message" $ do
      detectRedirection (RespError "") `shouldBe` Nothing

    it "detects MOVED redirect" $ do
      detectRedirection (RespError "MOVED 3999 127.0.0.1:6381")
        `shouldBe` Just (Left (RedirectionInfo 3999 "127.0.0.1" 6381))

    it "detects ASK redirect" $ do
      detectRedirection (RespError "ASK 3999 127.0.0.1:6381")
        `shouldBe` Just (Right (RedirectionInfo 3999 "127.0.0.1" 6381))

    it "returns Nothing for errors starting with M but not MOVED" $ do
      detectRedirection (RespError "MASTERDOWN Link with MASTER is down") `shouldBe` Nothing

    it "returns Nothing for errors starting with A but not ASK" $ do
      detectRedirection (RespError "AUTH required") `shouldBe` Nothing

  describe "ClusterError types" $ do
    it "creates MovedError correctly" $ do
      let err = MovedError 3999 (NodeAddress "127.0.0.1" 6381)
      show err `shouldContain` "MovedError"
      show err `shouldContain` "3999"

    it "creates AskError correctly" $ do
      let err = AskError 3999 (NodeAddress "127.0.0.1" 6381)
      show err `shouldContain` "AskError"
      show err `shouldContain` "3999"

    it "creates ClusterDownError correctly" $ do
      let err = ClusterDownError "Cluster is down"
      show err `shouldContain` "ClusterDownError"
      show err `shouldContain` "Cluster is down"

    it "creates TryAgainError correctly" $ do
      let err = TryAgainError "Try again later"
      show err `shouldContain` "TryAgainError"

    it "creates CrossSlotError correctly" $ do
      let err = CrossSlotError "Keys in request don't hash to the same slot"
      show err `shouldContain` "CrossSlotError"

    it "creates MaxRetriesExceeded correctly" $ do
      let err = MaxRetriesExceeded "Max retries (3) exceeded"
      show err `shouldContain` "MaxRetriesExceeded"
      show err `shouldContain` "3"

    it "creates TopologyError correctly" $ do
      let err = TopologyError "No node found for slot 3999"
      show err `shouldContain` "TopologyError"

    it "creates ConnectionError correctly" $ do
      let err = ConnectionError "Connection timeout"
      show err `shouldContain` "ConnectionError"

  describe "ClusterConfig" $ do
    it "creates valid cluster config" $ do
      let poolConfig = PoolConfig
            { maxConnectionsPerNode = 1,
              connectionTimeout = 5000,
              maxRetries = 3,
              useTLS = False
            }
          config = ClusterConfig
            { clusterSeedNode = NodeAddress "127.0.0.1" 7000,
              clusterPoolConfig = poolConfig,
              clusterMaxRetries = 3,
              clusterRetryDelay = 100000,
              clusterTopologyRefreshInterval = 600
            }
      clusterMaxRetries config `shouldBe` 3
      clusterRetryDelay config `shouldBe` 100000
      clusterTopologyRefreshInterval config `shouldBe` 600

  describe "RedirectionInfo" $ do
    it "creates valid redirection info" $ do
      let redir = RedirectionInfo 3999 "127.0.0.1" 6381
      redirSlot redir `shouldBe` 3999
      redirHost redir `shouldBe` "127.0.0.1"
      redirPort redir `shouldBe` 6381

    it "shows redirection info correctly" $ do
      let redir = RedirectionInfo 3999 "127.0.0.1" 6381
      show redir `shouldContain` "3999"
      show redir `shouldContain` "127.0.0.1"
      show redir `shouldContain` "6381"

    it "compares redirection info for equality" $ do
      let redir1 = RedirectionInfo 3999 "127.0.0.1" 6381
          redir2 = RedirectionInfo 3999 "127.0.0.1" 6381
          redir3 = RedirectionInfo 4000 "127.0.0.1" 6381
      redir1 `shouldBe` redir2
      redir1 `shouldNotBe` redir3
