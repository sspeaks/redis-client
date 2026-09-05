{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Data.ByteString                 (ByteString)
import           Database.Redis.Cluster.Commands
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Redis 7.2.12 smart-proxy key metadata" $ do
    it "has one table-driven valid case for every checked-in metadata form" $ do
      map (\(form, _, _, _) -> form) cases `shouldBe` commandForms
      mapM_ (\(_, command, args, expected) ->
        classifyCommand command args `shouldBe` expected) cases

    it "rejects malformed counts, arities, prefixes, and unknown commands locally" $
      mapM_ (\(command, args) ->
        classifyCommand command args `shouldSatisfy` isError)
        [ ("GET", ["key", "unexpected"]), ("RENAME", ["from"])
        , ("MSET", ["key"]), ("BLPOP", ["0"]), ("BLPOP", ["key", "forever"]), ("ZUNION", ["x"])
        , ("ZUNIONSTORE", ["destination", "-1"]), ("EVAL", ["return 1", "2", "key"])
        , ("XREAD", ["COUNT", "1", "STREAMS", "stream"])
        , ("XREADGROUP", ["GROUP", "group", "consumer", "COUNT", "1"])
        , ("XINFO", ["CONSUMERS", "stream"])
        , ("MEMORY", ["USAGE"]), ("OBJECT", ["ENCODING"])
        , ("GEOSEARCHSTORE", ["destination"]), ("NO_SUCH_COMMAND", ["key"])
        ]

isError :: CommandRouting -> Bool
isError (CommandError _) = True
isError _                = False

cases :: [(ByteString, ByteString, [ByteString], CommandRouting)]
cases =
  [ ("PING", "PING", [], KeylessRoute), ("ECHO", "ECHO", ["value"], KeylessRoute)
  , ("AUTH", "AUTH", ["password"], KeylessRoute), ("INFO", "INFO", [], KeylessRoute)
  , ("TIME", "TIME", [], KeylessRoute), ("COMMAND", "COMMAND", [], KeylessRoute)
  , ("CLUSTER", "CLUSTER", ["INFO"], KeylessRoute), ("CLIENT", "CLIENT", ["LIST"], KeylessRoute)
  , ("GET", "GET", ["key"], keyed ["key"]), ("SET", "SET", ["key", "value"], keyed ["key"])
  , ("MEMORY USAGE", "MEMORY", ["USAGE", "key"], keyed ["key"])
  , ("RENAME", "RENAME", ["a", "b"], keyed ["a", "b"]), ("RENAMENX", "RENAMENX", ["a", "b"], keyed ["a", "b"])
  , ("COPY", "COPY", ["a", "b"], keyed ["a", "b"]), ("DEL", "DEL", ["a", "b"], keyed ["a", "b"])
  , ("EXISTS", "EXISTS", ["a", "b"], keyed ["a", "b"]), ("MGET", "MGET", ["a", "b"], keyed ["a", "b"])
  , ("PFCOUNT", "PFCOUNT", ["a", "b"], keyed ["a", "b"]), ("TOUCH", "TOUCH", ["a", "b"], keyed ["a", "b"])
  , ("UNLINK", "UNLINK", ["a", "b"], keyed ["a", "b"]), ("WATCH", "WATCH", ["a", "b"], keyed ["a", "b"])
  , ("MSET", "MSET", ["a", "1", "b", "2"], keyed ["a", "b"])
  , ("BLPOP", "BLPOP", ["a", "b", "0"], keyed ["a", "b"]), ("BRPOP", "BRPOP", ["a", "b", "0"], keyed ["a", "b"])
  , ("BZPOPMIN", "BZPOPMIN", ["a", "b", "0"], keyed ["a", "b"]), ("BZPOPMAX", "BZPOPMAX", ["a", "b", "0"], keyed ["a", "b"])
  , ("ZUNION", "ZUNION", ["2", "a", "b"], keyed ["a", "b"]), ("ZINTER", "ZINTER", ["2", "a", "b"], keyed ["a", "b"])
  , ("ZDIFF", "ZDIFF", ["2", "a", "b"], keyed ["a", "b"]), ("ZUNIONSTORE", "ZUNIONSTORE", ["destination", "2", "a", "b"], keyed ["destination", "a", "b"])
  , ("ZINTERSTORE", "ZINTERSTORE", ["destination", "2", "a", "b"], keyed ["destination", "a", "b"])
  , ("ZDIFFSTORE", "ZDIFFSTORE", ["destination", "2", "a", "b"], keyed ["destination", "a", "b"])
  , ("EVAL", "EVAL", ["return 1", "1", "key"], keyed ["key"]), ("EVALSHA", "EVALSHA", ["sha", "1", "key"], keyed ["key"])
  , ("FCALL", "FCALL", ["function", "1", "key"], keyed ["key"]), ("FCALL_RO", "FCALL_RO", ["function", "1", "key"], keyed ["key"])
  , ("XREAD", "XREAD", ["COUNT", "1", "STREAMS", "a", "0"], keyed ["a"])
  , ("XREADGROUP", "XREADGROUP", ["GROUP", "g", "c", "STREAMS", "a", ">"], keyed ["a"])
  , ("XINFO STREAM", "XINFO", ["STREAM", "a"], keyed ["a"]), ("XINFO GROUPS", "XINFO", ["GROUPS", "a"], keyed ["a"])
  , ("XINFO CONSUMERS", "XINFO", ["CONSUMERS", "a", "g"], keyed ["a"])
  , ("OBJECT ENCODING", "OBJECT", ["ENCODING", "a"], keyed ["a"]), ("OBJECT FREQ", "OBJECT", ["FREQ", "a"], keyed ["a"])
  , ("OBJECT IDLETIME", "OBJECT", ["IDLETIME", "a"], keyed ["a"]), ("OBJECT REFCOUNT", "OBJECT", ["REFCOUNT", "a"], keyed ["a"])
  , ("GEOSEARCH", "GEOSEARCH", ["a"], keyed ["a"]), ("GEOSEARCHSTORE", "GEOSEARCHSTORE", ["destination", "a"], keyed ["destination", "a"])
  , ("GEORADIUS", "GEORADIUS", ["a"], keyed ["a"]), ("GEORADIUSBYMEMBER", "GEORADIUSBYMEMBER", ["a"], keyed ["a"])
  ]
  where
    keyed = KeyedRoute
