{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Data.ByteString                 (ByteString)
import qualified Data.Set                        as Set
import           Database.Redis.Cluster.Commands
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "generated grammar metadata integrity" $ do
    it "contains maintained known-form command heads in routing sets" $ do
      let maintained =
            Set.fromList
              [ "SET"
              , "MEMORY"
              , "OBJECT"
              , "ZUNION"
              , "ZINTER"
              , "ZDIFF"
              , "XINFO"
              , "XREAD"
              , "XREADGROUP"
              , "BLPOP"
              , "BRPOP"
              , "PFCOUNT"
              , "TOUCH"
              , "UNLINK"
              , "WATCH"
              , "MSET"
              , "RENAME"
              , "RENAMENX"
              , "COPY"
              , "EVAL"
              , "EVALSHA"
              , "FCALL"
              , "GEOSEARCH"
              , "GEORADIUS"
              , "GEORADIUSBYMEMBER"
              ]
          available = Set.fromList (keylessCommands ++ requiresKeyCommands)
      maintained `Set.isSubsetOf` available `shouldBe` True

    it "rejects representative arity failures for maintained grammar forms" $ do
      let invalidCases =
            [ ["SET", "only-key"]
            , ["MEMORY", "USAGE"]
            , ["OBJECT"]
            , ["ZUNION", "2", "k1"]
            , ["XREAD", "STREAMS", "k1"]
            , ["XREADGROUP", "GROUP", "g", "c", "STREAMS", "k1"]
            , ["MSET", "k1", "v1", "k2"]
            , ["EVAL", "script", "2", "k1"]
            , ["GEOSEARCH", "k"]
            ]
      mapM_ (\parts -> classifyParts parts `shouldSatisfy` isCommandError) invalidCases

  describe "classifyCommand known required grammar forms" $ do
    it "routes SET and rejects malformed SET options locally" $ do
      classifyCommand "SET" ["k", "v", "nx", "get"]
        `shouldBe` KeyedRoute "k"
      classifyCommand "SET" ["k", "v", "GET", "extra"]
        `shouldSatisfy` isCommandError

    it "routes MEMORY and OBJECT subcommands by grammar" $ do
      classifyCommand "MEMORY" ["USAGE", "cache:key"] `shouldBe` KeyedRoute "cache:key"
      classifyCommand "MEMORY" ["HELP"] `shouldBe` KeylessRoute
      classifyCommand "OBJECT" ["HELP"] `shouldBe` KeylessRoute
      classifyCommand "OBJECT" ["ENCODING", "obj:key"] `shouldBe` KeyedRoute "obj:key"

    it "handles Z* set operation counts/options and rejects malformed combinations" $ do
      classifyCommand "ZUNION"
        ["2", "{u}a", "{u}b", "WEIGHTS", "1", "2", "AGGREGATE", "MAX", "WITHSCORES"]
        `shouldBe` KeyedRoute "{u}a"
      classifyCommand "ZDIFF" ["2", "a", "b", "AGGREGATE", "SUM"]
        `shouldSatisfy` isCommandError

    it "validates XREAD/XREADGROUP STREAMS structure" $ do
      classifyCommand "XREAD" ["COUNT", "2", "STREAMS", "{s}k1", "{s}k2", "0-0", "$"]
        `shouldBe` KeyedRoute "{s}k1"
      classifyCommand "XREADGROUP"
        ["GROUP", "g", "c", "STREAMS", "k1"]
        `shouldSatisfy` isCommandError

    it "supports fractional BLPOP timeout and key-count commands" $ do
      classifyCommand "BLPOP" ["{l}1", "{l}2", "0.25"] `shouldBe` KeyedRoute "{l}1"
      classifyCommand "PFCOUNT" ["{h}1", "{h}2"] `shouldBe` KeyedRoute "{h}1"
      classifyCommand "TOUCH" ["{h}1", "{h}2"] `shouldBe` KeyedRoute "{h}1"
      classifyCommand "UNLINK" ["{h}1", "{h}2"] `shouldBe` KeyedRoute "{h}1"
      classifyCommand "WATCH" ["{h}1", "{h}2"] `shouldBe` KeyedRoute "{h}1"

    it "validates MSET pairs and copy/rename style commands" $ do
      classifyCommand "MSET" ["{m}1", "a", "{m}2", "b"] `shouldBe` KeyedRoute "{m}1"
      classifyCommand "MSET" ["key", "value", "orphan"] `shouldSatisfy` isCommandError
      classifyCommand "RENAME" ["{r}a", "{r}b"] `shouldBe` KeyedRoute "{r}a"
      classifyCommand "RENAMENX" ["{r}a", "{r}b"] `shouldBe` KeyedRoute "{r}a"
      classifyCommand "COPY" ["{c}src", "{c}dst", "REPLACE"] `shouldBe` KeyedRoute "{c}src"

    it "validates counted-key commands (EVAL/EVALSHA/FCALL)" $ do
      classifyCommand "EVAL" ["return 1", "2", "{e}1", "{e}2", "arg"] `shouldBe` KeyedRoute "{e}1"
      classifyCommand "EVALSHA" ["sha", "1", "{e}1"] `shouldBe` KeyedRoute "{e}1"
      classifyCommand "FCALL" ["fn", "2", "{f}1", "{f}2"] `shouldBe` KeyedRoute "{f}1"
      classifyCommand "EVAL" ["return 1", "3", "{e}1"] `shouldSatisfy` isCommandError

    it "parses GEOSEARCH and GEORADIUS/BYMEMBER mutable options" $ do
      classifyCommand "GEOSEARCH"
        ["gk", "FROMMEMBER", "m", "BYRADIUS", "50", "KM", "COUNT", "2", "ANY", "ASC"]
        `shouldBe` KeyedRoute "gk"
      classifyCommand "GEORADIUS"
        ["{g}k", "13", "37", "5", "km", "STORE", "{g}dst"]
        `shouldBe` KeyedRoute "{g}k"
      classifyCommand "GEORADIUSBYMEMBER"
        ["{g}k", "m", "5", "km", "STOREDIST", "{g}dst"]
        `shouldBe` KeyedRoute "{g}k"

    it "supports case-insensitive command/subcommand/options and rejects unknown policy locally" $ do
      classifyCommand "memory" ["usage", "Key"] `shouldBe` KeyedRoute "Key"
      classifyCommand "xinfo" ["help"] `shouldBe` KeylessRoute
      classifyCommand "set" ["k", "v", "Nx"] `shouldBe` KeyedRoute "k"
      classifyCommand "NO_SUCH_COMMAND" ["k"] `shouldSatisfy` isCommandError

    it "rejects cross-slot commands before dispatch with local grammar errors" $ do
      classifyCommand "MSET" ["{a}k1", "v1", "{b}k2", "v2"]
        `shouldSatisfy` isCommandError
      classifyCommand "XREAD" ["STREAMS", "{x}a", "{y}b", "0-0", "0-0"]
        `shouldSatisfy` isCommandError

classifyParts :: [ByteString] -> CommandRouting
classifyParts []         = CommandError "empty"
classifyParts (cmd:args) = classifyCommand cmd args

isCommandError :: CommandRouting -> Bool
isCommandError (CommandError _) = True
isCommandError _                = False
