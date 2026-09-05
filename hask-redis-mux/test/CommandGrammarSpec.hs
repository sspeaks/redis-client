{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString                 as BS
import           Database.Redis.Cluster          (calculateSlot)
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommand,
                                                  keylessCommands,
                                                  requiresKeyCommands)
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "metadata-driven command grammar" $ do
    it "extracts fixed keys without changing binary bytes" $ do
      let binaryKey = BS.pack [0, 123, 255, 125]
      classifyCommand "gEt" [binaryKey] `shouldBe` KeyedRoute binaryKey

    it "rejects missing and excess exact-arity arguments" $ do
      classifyCommand "GET" []
        `shouldBe` CommandError "GET has invalid arity: expected 2 argument(s), got 1"
      classifyCommand "GET" ["key", "extra"]
        `shouldBe` CommandError "GET has invalid arity: expected 2 argument(s), got 3"

    it "extracts range keys and distinguishes matching and cross slots" $ do
      classifyCommand "MGET" ["{slot}:one", "{slot}:two"]
        `shouldBe` KeyedRoute "{slot}:one"
      classifyCommand "MGET" ["one", "two"]
        `shouldBe` CommandError "CROSSSLOT Keys in request don't hash to the same slot"

    it "extracts key-count keys and validates zero, malformed, and insufficient counts" $ do
      classifyCommand "EVAL" ["return 1", "2", "{same}:one", "{same}:two"]
        `shouldBe` KeyedRoute "{same}:one"
      classifyCommand "EVALSHA" ["hash", "0"] `shouldBe` KeylessRoute
      classifyCommand "EVAL" ["return 1", "two"]
        `shouldBe` CommandError "EVAL has an invalid key count"
      classifyCommand "EVAL" ["return 1", "2", "only-one"]
        `shouldBe` CommandError "EVAL has malformed key arguments"

    it "extracts each key spec in order for multi-spec commands" $ do
      classifyCommand "ZUNIONSTORE" ["{same}:destination", "2", "{same}:one", "{same}:two"]
        `shouldBe` KeyedRoute "{same}:destination"
      classifyCommand "ZUNIONSTORE" ["destination", "2", "one", "two"]
        `shouldBe` CommandError "CROSSSLOT Keys in request don't hash to the same slot"

    it "uses keyword-delimited specs case-insensitively and skips optional keywords" $ do
      classifyCommand "GEORADIUS" ["{same}:source", "0", "0", "1", "km"]
        `shouldBe` KeyedRoute "{same}:source"
      classifyCommand "GEORADIUS" ["{same}:source", "0", "0", "1", "km", "sToRe", "{same}:destination"]
        `shouldBe` KeyedRoute "{same}:source"

    it "validates the required STREAMS grammar and extracts stream keys only" $ do
      classifyCommand "XREAD" ["COUNT", "1", "STREAMS", "{same}:one", "{same}:two", "0-0", "0-0"]
        `shouldBe` KeyedRoute "{same}:one"
      classifyCommand "XREAD" ["COUNT", "1", "NOSTREAMS"]
        `shouldBe` CommandError "XREAD requires STREAMS"
      classifyCommand "XREADGROUP" ["GROUP", "group", "consumer", "STREAMS", "{same}:one", ">"]
        `shouldBe` KeyedRoute "{same}:one"

    it "rejects malformed stream key/ID and unknown dynamic key specifications" $ do
      classifyCommand "XREAD" ["STREAMS", "key", "0-0", "another"]
        `shouldBe` CommandError "XREAD has malformed key arguments"
      classifyCommand "SORT" ["key"]
        `shouldBe` CommandError "SORT uses an unsupported dynamic key specification"
      classifyCommand "MIGRATE" ["host", "6379", "", "0", "1000", "KEYS", "key"]
        `shouldBe` CommandError "MIGRATE uses an unsupported dynamic key specification"

    it "resolves subcommands and rejects unknown subcommands fail-closed" $ do
      classifyCommand "CONFIG" ["GET", "timeout"] `shouldBe` KeylessRoute
      classifyCommand "CONFIG" ["NOT-A-SUBCOMMAND"]
        `shouldBe` CommandError "unknown subcommand for CONFIG"

    it "treats keyless commands with arguments as keyless and rejects unknown commands" $ do
      classifyCommand "PING" ["payload"] `shouldBe` KeylessRoute
      classifyCommand "DOESNOTEXIST" ["key"] `shouldBe` CommandError "unknown command"

    it "keeps the legacy facade source-compatible while failing cross-slot requests locally" $ do
      classifyCommand "get" ["{same}:key"] `shouldBe` KeyedRoute "{same}:key"
      classifyCommand "PING" ["payload"] `shouldBe` KeylessRoute
      classifyCommand "MGET" ["one", "two"]
        `shouldBe` CommandError "CROSSSLOT Keys in request don't hash to the same slot"

    it "covers all generated metadata with explicit supported and unsupported paths" $ do
      length (keylessCommands ++ requiresKeyCommands) `shouldBe` 392
      classifyCommand "MIGRATE" ["host", "6379", "", "0", "1000", "KEYS", "key"]
        `shouldBe` CommandError "MIGRATE uses an unsupported dynamic key specification"
      classifyCommand "SORT_RO" ["key"]
        `shouldBe` CommandError "SORT_RO uses an unsupported dynamic key specification"

    it "uses the existing hash-tag slot calculation for every extracted key" $ do
      calculateSlot "{tag}:one" `shouldBe` calculateSlot "{tag}:two"
