{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel                   (rewriteClusterResponse)
import           Database.Redis.Cluster.Commands (keyArguments,
                                                  keyArgumentsFromResp)
import           Database.Redis.Resp             (RespData (..))
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "rewriteClusterResponse" $ do
    it "rewrites exactly one complete RESP response" $ do
      rewriteClusterResponse "-MOVED 3999 redis.example:6381\r\n"
        `shouldBe` "-MOVED 3999 127.0.0.1:6381\r\n"

    it "does not drop a concatenated response" $ do
      let responses = "-MOVED 3999 redis.example:6381\r\n+OK\r\n"
      rewriteClusterResponse responses `shouldBe` responses

    it "leaves malformed framing unchanged" $ do
      let malformed = "-MOVED 3999 redis.example:6381\rX"
      rewriteClusterResponse malformed `shouldBe` malformed

  describe "checked-in cluster key specifications" $ do
    it "selects fixed first and later key positions" $ do
      keyArguments "GET" ["key"] `shouldBe` Right ["key"]
      keyArguments "BITOP" ["AND", "destination", "source"]
        `shouldBe` Right ["destination", "source"]

    it "extracts every key from same-slot multi-key commands" $ do
      keyArguments "ZUNIONSTORE" ["{tag}:out", "2", "{tag}:one", "{tag}:two"]
        `shouldBe` Right ["{tag}:out", "{tag}:one", "{tag}:two"]
      keyArguments "MSET" ["{tag}:one", "one", "{tag}:two", "two"]
        `shouldBe` Right ["{tag}:one", "{tag}:two"]

    it "handles movable EVAL and stream key lists" $ do
      keyArguments "EVAL" ["return KEYS[1]", "1", "key", "argument"]
        `shouldBe` Right ["key"]
      keyArguments "XREADGROUP" ["GROUP", "g", "c", "STREAMS", "one", "two", ">", ">"]
        `shouldBe` Right ["one", "two"]

    it "keeps keyless commands keyless when they have arguments" $
      keyArgumentsFromResp "ECHO" [RespInteger 42] `shouldBe` Right []

    it "preserves binary non-key RESP arguments for raw forwarding" $
      keyArgumentsFromResp "SET" [RespBulkString "key", RespBulkString "\NUL\255"]
        `shouldBe` Right ["key"]

    it "fails closed for unknown commands and malformed movable specs" $ do
      keyArguments "MODULE.FUTURE" ["might-be-a-key"]
        `shouldBe` Left "unsupported command for cluster routing: MODULE.FUTURE"
      keyArguments "EVALSHA" ["digest", "not-a-number"]
        `shouldBe` Left "command EVALSHA has an invalid key count"
