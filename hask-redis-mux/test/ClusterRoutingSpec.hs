{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Data.List                       (isInfixOf)
import           Database.Redis.Cluster.Commands
import           Database.Redis.Resp             (RespData (..))
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "generated command coverage" $ do
    it "derives maintained command counts from generated metadata" $ do
      let total = length keylessCommands + length requiresKeyCommands
      total `shouldBe` supportedCommandCount

  describe "key routing grammar" $ do
    it "accepts SET with case-insensitive options" $ do
      classifyCommand "SET" ["key", "value", "px", "10", "gEt"]
        `shouldBe` KeyedRoute "key"

    it "rejects invalid SET option combinations" $ do
      classifyCommand "SET" ["key", "value", "NX", "XX"]
        `shouldSatisfy` isErrorContaining "mutually exclusive"
      classifyCommand "SET" ["key", "value", "GET", "GET"]
        `shouldSatisfy` isErrorContaining "must not be repeated"

    it "rejects bogus CLIENT/MEMORY subcommands and CLIENT ID junk" $ do
      classifyCommand "CLIENT" ["ID", "junk"]
        `shouldSatisfy` isErrorContaining "does not accept extra arguments"
      classifyCommand "CLIENT" ["BOGUS"]
        `shouldSatisfy` isErrorContaining "Unknown CLIENT subcommand"
      classifyCommand "MEMORY" ["BOGUS"]
        `shouldSatisfy` isErrorContaining "Unknown MEMORY subcommand"

    it "parses ZUNION/ZINTER/ZDIFF forms and validates counts" $ do
      classifyCommand "ZUNION" ["2", "{t}1", "{t}2", "WEIGHTS", "1.0", "2.0", "AGGREGATE", "MAX", "WITHSCORES"]
        `shouldBe` KeyedRoute "{t}1"
      classifyCommand "ZINTER" ["2", "z1", "z2", "WITHSCORES"]
        `shouldSatisfy` isErrorContaining "CROSSSLOT"
      classifyCommand "ZDIFF" ["2", "only-one-key"]
        `shouldSatisfy` isErrorContaining "Declared key count"

    it "supports XINFO, XREAD, and XREADGROUP grammar" $ do
      classifyCommand "XINFO" ["STREAM", "s"]
        `shouldBe` KeyedRoute "s"
      classifyCommand "XREAD" ["COUNT", "2", "STREAMS", "{s}a", "{s}b", "0-0", "$"]
        `shouldBe` KeyedRoute "{s}a"
      classifyCommand "XREADGROUP" ["GROUP", "g", "c", "BLOCK", "1", "STREAMS", "k1", "0-0"]
        `shouldBe` KeyedRoute "k1"
      classifyCommand "XREADGROUP" ["GROUP", "g", "c", "STREAMS", "k1"]
        `shouldSatisfy` isErrorContaining "equal numbers of keys and IDs"

    it "validates MSET/MSETNX pairs, BLPOP timeout, and script key counts" $ do
      classifyCommand "MSETNX" ["{h}a", "1", "{h}b", "2"]
        `shouldBe` KeyedRoute "{h}a"
      classifyCommand "MSETNX" ["k1", "v1", "k2"]
        `shouldSatisfy` isErrorContaining "key/value pairs"
      classifyCommand "BLPOP" ["{q}1", "{q}2", "0.25"]
        `shouldBe` KeyedRoute "{q}1"
      classifyCommand "BRPOP" ["q1", "oops"]
        `shouldSatisfy` isErrorContaining "timeout must be numeric"
      classifyCommand "EVALSHA" ["sha", "2", "{x}1", "{x}2", "arg"]
        `shouldBe` KeyedRoute "{x}1"
      classifyCommand "FCALL" ["fn", "2", "k1", "k2"]
        `shouldSatisfy` isErrorContaining "CROSSSLOT"

    it "rejects cross-slot pair-key commands and unknown commands" $ do
      classifyCommand "RENAME" ["a", "b"]
        `shouldSatisfy` isErrorContaining "CROSSSLOT"
      classifyCommand "COPY" ["{c}1", "{c}2", "DB", "0", "REPLACE"]
        `shouldBe` KeyedRoute "{c}1"
      classifyCommand "GEOSEARCHSTORE" ["a", "b", "FROMMEMBER", "m", "BYRADIUS", "1", "km"]
        `shouldSatisfy` isErrorContaining "CROSSSLOT"
      classifyCommand "NOTREAL" []
        `shouldSatisfy` isErrorContaining "Unknown or unsupported"

    it "classifies RESP arrays without discarding argument types" $ do
      classifyRespCommand (RespArray [RespBulkString "SET", RespBulkString "k", RespBulkString "v", RespSimpleString "NX"])
        `shouldBe` KeyedRoute "k"
      classifyRespCommand (RespArray [RespBulkString "CLIENT", RespBulkString "ID", RespInteger 1])
        `shouldSatisfy` isErrorContaining "does not accept extra arguments"

isErrorContaining :: String -> CommandRouting -> Bool
isErrorContaining needle (CommandError msg) = needle `isInfixOf` msg
isErrorContaining _ _                       = False
