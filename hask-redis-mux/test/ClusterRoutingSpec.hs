{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Data.ByteString                 (ByteString)
import           Database.Redis.Cluster.Commands
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "subcommand validation" $ do
    assertError "MEMORY" ["BOGUS"]
    assertError "CLIENT" ["BOGUS"]
    assertError "XINFO" ["BOGUS"]

  describe "grammar validation" $ do
    assertError "XREAD" ["NOACK"]
    assertError "MSETNX" ["k1", "v1", "k2"]
    assertError "MSET" ["k1", "v1", "k2"]
    assertError "SET" ["k", "v", "GET", "GET"]
    assertError "GET" ["k", "extra"]
    assertError "ZUNION" ["2", "{h}a", "{h}b", "WEIGHTS", "1"]
    assertError "EVAL" ["return 1", "2", "k1"]
    assertError "FCALL" ["f", "2", "k1"]

  describe "valid command routing" $ do
    assertKeyed "SET" ["{h}key", "value"] "{h}key"
    assertKeyed "OBJECT" ["ENCODING", "{h}key"] "{h}key"
    assertKeyed "ZUNION" ["2", "{h}a", "{h}b", "WEIGHTS", "1", "2", "AGGREGATE", "MAX", "WITHSCORES"] "{h}a"
    assertKeyed "ZINTER" ["2", "{h}a", "{h}b", "WEIGHTS", "1", "2", "AGGREGATE", "SUM", "WITHSCORES"] "{h}a"
    assertKeyed "ZDIFF" ["2", "{h}a", "{h}b", "WITHSCORES"] "{h}a"
    assertKeyed "XINFO" ["STREAM", "{h}stream"] "{h}stream"
    assertKeyed "BLPOP" ["{h}list", "0.25"] "{h}list"
    assertKeyed "BRPOP" ["{h}list", "0.5"] "{h}list"
    assertKeyed "PFCOUNT" ["{h}a", "{h}b"] "{h}a"
    assertKeyed "TOUCH" ["{h}a", "{h}b"] "{h}a"
    assertKeyed "UNLINK" ["{h}a", "{h}b"] "{h}a"
    assertKeyed "WATCH" ["{h}a", "{h}b"] "{h}a"
    assertKeyed "MSET" ["{h}a", "1", "{h}b", "2"] "{h}a"
    assertKeyed "MSETNX" ["{h}a", "1", "{h}b", "2"] "{h}a"
    assertKeyed "RENAME" ["{h}a", "{h}b"] "{h}a"
    assertKeyed "COPY" ["{h}a", "{h}b", "REPLACE"] "{h}a"
    assertKeyed "XREAD" ["COUNT", "2", "BLOCK", "10", "STREAMS", "{h}s1", "{h}s2", "0-0", "0-1"] "{h}s1"
    assertKeyed "XREADGROUP" ["GROUP", "g", "c", "COUNT", "2", "BLOCK", "10", "STREAMS", "{h}s1", "{h}s2", ">", ">"] "{h}s1"
    assertKeyed "EVAL" ["return ARGV[1]", "2", "{h}k1", "{h}k2", "arg"] "{h}k1"
    assertKeyed "FCALL" ["myf", "2", "{h}k1", "{h}k2", "arg"] "{h}k1"
    assertKeyed "GEOSEARCHSTORE" ["{h}dst", "{h}src", "FROMMEMBER", "m", "BYRADIUS", "1.2", "km", "COUNT", "1", "ANY", "STOREDIST"] "{h}dst"

    it "accepts OBJECT HELP as keyless" $ do
      classifyCommand "OBJECT" ["HELP"] `shouldBe` KeylessRoute

assertError :: ByteString -> [ByteString] -> Spec
assertError cmd args =
  it (show cmd ++ " rejects malformed input") $ do
    classifyCommand cmd args `shouldSatisfy` isCommandError

assertKeyed :: ByteString -> [ByteString] -> ByteString -> Spec
assertKeyed cmd args expectedKey =
  it (show cmd ++ " routes by key") $ do
    classifyCommand cmd args `shouldBe` KeyedRoute expectedKey

isCommandError :: CommandRouting -> Bool
isCommandError routing =
  case routing of
    CommandError _ -> True
    _              -> False
