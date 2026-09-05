{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel                              (rewriteClusterResponse,
                                                             routeSmartProxyCommandWith)
import qualified Data.ByteString                            as BS
import           Data.IORef                                 (modifyIORef',
                                                             newIORef,
                                                             readIORef)
import           Database.Redis.Cluster.Internal.RawCommand (RawClusterRoute (..))
import           Database.Redis.Resp
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "smart proxy command routing" $ do
    it "hands the original keyed GET frame to raw dispatch" $ do
      let frame = commandFrame ["GET", "profile:key"]
      assertDispatch frame (RawRouteByKey "profile:key")

    it "preserves binary keys, values, command case, and option order" $ do
      let binaryKey = "\NUL{binary}\255"
          frame = commandFrame ["sEt", binaryKey, "\255value", "NX", "PX", "10"]
      assertDispatch frame (RawRouteByKey binaryKey)

    it "routes a keyless command with arguments through raw keyless dispatch" $ do
      let frame = commandFrame ["PING", "payload"]
      assertDispatch frame RawRouteKeyless

    it "uses metadata keys for subcommands and key-count commands" $ do
      assertDispatch
        (commandFrame ["CLIENT", "NO-EVICT", "ON"])
        RawRouteKeyless
      assertDispatch
        (commandFrame ["EVAL", "return 1", "2", "{slot}:one", "{slot}:two"])
        (RawRouteByKey "{slot}:one")

    it "uses metadata keys for stream, store, and multi-key commands" $ do
      assertDispatch
        (commandFrame ["XREAD", "COUNT", "1", "STREAMS", "{slot}:one", "{slot}:two", "0-0", "0-0"])
        (RawRouteByKey "{slot}:one")
      assertDispatch
        (commandFrame ["XREADGROUP", "GROUP", "group", "consumer", "STREAMS", "{slot}:one", ">"])
        (RawRouteByKey "{slot}:one")
      assertDispatch
        (commandFrame ["ZUNIONSTORE", "{slot}:destination", "2", "{slot}:one", "{slot}:two"])
        (RawRouteByKey "{slot}:destination")
      assertDispatch
        (commandFrame ["MGET", "{slot}:one", "{slot}:two"])
        (RawRouteByKey "{slot}:one")

    it "does not dispatch cross-slot, malformed, dynamic, unknown, or non-bulk frames" $ do
      assertNoDispatch
        (commandFrame ["MGET", "first", "second"])
        "CROSSSLOT Keys in request don't hash to the same slot"
      assertNoDispatch
        (commandFrame ["GET"])
        "GET has invalid arity: expected 2 argument(s), got 1"
      assertNoDispatch
        (commandFrame ["SORT", "key", "BY", "pattern"])
        "SORT uses an unsupported dynamic key specification"
      assertNoDispatch
        (commandFrame ["NOTACOMMAND", "key"])
        "unknown command"
      assertNoDispatch
        (RespArray [RespBulkString "GET", RespInteger 1])
        "Expected array command with bulk string arguments"

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

commandFrame :: [BS.ByteString] -> RespData
commandFrame = RespArray . fmap RespBulkString

assertDispatch :: RespData -> RawClusterRoute -> Expectation
assertDispatch frame expectedRoute = do
  dispatched <- newIORef []
  result <- routeSmartProxyCommandWith
    (\route originalFrame -> do
      modifyIORef' dispatched (<> [(route, originalFrame)])
      pure $ Right (RespSimpleString "OK"))
    frame
  result `shouldBe` Right (RespSimpleString "OK")
  observed <- readIORef dispatched
  observed `shouldBe` [(expectedRoute, frame)]

assertNoDispatch :: RespData -> String -> Expectation
assertNoDispatch frame expectedError = do
  dispatchCount <- newIORef (0 :: Int)
  result <- routeSmartProxyCommandWith
    (\_ _ -> do
      modifyIORef' dispatchCount (+ 1)
      pure $ Right (RespSimpleString "unexpected"))
    frame
  result `shouldBe` Left expectedError
  observedDispatches <- readIORef dispatchCount
  observedDispatches `shouldBe` 0
