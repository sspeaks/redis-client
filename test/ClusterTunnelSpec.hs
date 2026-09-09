{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel                              (PinnedResponseResult (..),
                                                             SmartProxyFrameResult (..),
                                                             parsePinnedResponses,
                                                             parsePinnedResponsesWithLimit,
                                                             parseSmartProxyFrames,
                                                             rewriteClusterResponse,
                                                             routeSmartProxyCommandWith,
                                                             smartProxyFrameLimit)
import           Control.Monad                              (foldM)
import qualified Data.ByteString                            as BS
import qualified Data.ByteString.Builder                    as Builder
import qualified Data.ByteString.Char8                      as BS8
import qualified Data.ByteString.Lazy                       as LBS
import           Data.IORef                                 (modifyIORef',
                                                             newIORef,
                                                             readIORef)
import           Database.Redis.Cluster.Internal.RawCommand (RawClusterRoute (..))
import           Database.Redis.Resp
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "smart proxy TCP framing" $ do
    it "accepts a binary request split at every byte boundary exactly once" $ do
      let frame = commandFrame ["SET", "fragment:key", BS.cons 0 $ BS.cons 255 $ BS.replicate 5000 42]
          wire = encodeFrame frame
      mapM_ (assertSplitFrame frame wire) [1 .. BS.length wire - 1]

    it "drains pipelined commands in wire order and retains a partial suffix" $ do
      let first = commandFrame ["PING"]
          second = commandFrame ["ECHO", "second"]
          partialThird = BS.take 6 $ encodeFrame (commandFrame ["GET", "later"])
      parseSmartProxyFrames BS.empty (encodeFrame first <> encodeFrame second <> partialThird)
        `shouldBe` SmartProxyFrames [first, second] partialThird

    it "does not reinterpret bytes after malformed framing as another command" $ do
      let first = commandFrame ["PING"]
          malformedThenValid = "?bad\r\n" <> encodeFrame (commandFrame ["PING"])
      case parseSmartProxyFrames BS.empty (encodeFrame first <> malformedThenValid) of
        SmartProxyFrameError commands _ ->
          commands `shouldBe` [first]
        SmartProxyFrames {} ->
          expectationFailure "malformed input was accepted"

    it "retains incomplete input and enforces the explicit frame limit" $ do
      let incomplete = "$1048576\r\n" <> BS.replicate smartProxyFrameLimit 42
      parseSmartProxyFrames BS.empty "$5\r\nabc"
        `shouldBe` SmartProxyFrames [] "$5\r\nabc"
      case parseSmartProxyFrames BS.empty incomplete of
        SmartProxyFrameError [] _ -> pure ()
        _                        -> expectationFailure "oversized partial frame was accepted"

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

    it "acquires no transport for every rejected smart-proxy frame shape" $ do
      let rejectedFrames =
            [ ( RespArray []
              , "Expected array command with bulk string arguments"
              )
            , ( RespSimpleString "GET"
              , "Expected array command with bulk string arguments"
              )
            , ( RespArray [RespSimpleString "GET", RespBulkString "key"]
              , "Expected array command with bulk string arguments"
              )
            , ( commandFrame ["GET"]
              , "GET has invalid arity: expected 2 argument(s), got 1"
              )
            , ( commandFrame ["DOESNOTEXIST", "key"]
              , "unknown command"
              )
            , ( commandFrame ["SORT", "key", "STORE", "destination"]
              , "SORT uses an unsupported dynamic key specification"
              )
            , ( commandFrame ["MSET", "one", "value", "two"]
              , "MSET has malformed arguments"
              )
            , ( commandFrame ["MGET", "one", "two"]
              , "CROSSSLOT Keys in request don't hash to the same slot"
              )
            ]
      mapM_ (uncurry assertNoDispatch) rejectedFrames

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

  describe "pinned response TCP framing" $ do
    it "retains fragmented topology frames and rewrites only after completion" $ do
      let response = "-MOVED 3999 redis.example:6381\r\n"
          (firstChunk, secondChunk) = BS.splitAt 12 response
      parsePinnedResponses BS.empty firstChunk
        `shouldBe` PinnedResponses BS.empty firstChunk
      parsePinnedResponses firstChunk secondChunk
        `shouldBe` PinnedResponses "-MOVED 3999 127.0.0.1:6381\r\n" BS.empty

    it "drains coalesced replies in order and preserves untouched binary bytes" $ do
      let binary = "$5\r\n\NUL\255\r\n*\r\n"
          responses = "-ASK 10 redis.example:6382\r\n" <> binary <> "+OK\r\n"
      parsePinnedResponses BS.empty responses
        `shouldBe` PinnedResponses
          ("-ASK 10 127.0.0.1:6382\r\n" <> binary <> "+OK\r\n")
          BS.empty

    it "passes unsupported RESP3 push bytes through without blocking" $ do
      let push = ">2\r\n+message\r\n+payload\r\n"
      parsePinnedResponses BS.empty push
        `shouldBe` PinnedResponses push BS.empty

    it "preserves fragmented RESP3 pushes while rewriting later coalesced topology frames" $ do
      let push = ">2\r\n+message\r\n+payload\r\n"
          moved = "-MOVED 3999 redis.example:6381\r\n"
          (firstChunk, secondChunk) = BS.splitAt 11 (push <> moved)
      parsePinnedResponses BS.empty firstChunk
        `shouldBe` PinnedResponses BS.empty firstChunk
      parsePinnedResponses firstChunk secondChunk
        `shouldBe` PinnedResponses
          (push <> "-MOVED 3999 127.0.0.1:6381\r\n")
          BS.empty

    it "preserves a streamed blob payload exactly before rewriting a later response" $ do
      let payload = "x\n-MOVED 3999 redis.example:6381\r\n\NUL\255\n-ASK 10 redis.example:6382\r\n"
          stream = streamedBlob [payload]
          moved = "-MOVED 3999 redis.example:6381\r\n"
          expected = stream <> "-MOVED 3999 127.0.0.1:6381\r\n"
      parsePinnedResponses BS.empty (stream <> moved)
        `shouldBe` PinnedResponses expected BS.empty
      assertPinnedResponseAcrossSplits (stream <> moved) expected

    it "frames nested streamed aggregates and multiple chunks before later rewrites" $ do
      let blob = streamedBlob ["first\n", "-ASK 10 redis.example:6382\r\n"]
          nested = "*?\r\n" <> blob <> ">?\r\n+message\r\n" <> streamedBlob ["payload"] <> ".\r\n.\r\n"
          ask = "-ASK 10 redis.example:6382\r\n"
          expected = nested <> "-ASK 10 127.0.0.1:6382\r\n"
      parsePinnedResponses BS.empty (nested <> ask)
        `shouldBe` PinnedResponses expected BS.empty
      assertPinnedResponseAcrossSplits (nested <> ask) expected

    it "resumes framing after an opaque malformed record without swallowing later rewrites" $ do
      let malformed = "?bad\r\n"
          ask = "-ASK 10 redis.example:6382\r\n"
      parsePinnedResponses BS.empty (malformed <> ask)
        `shouldBe` PinnedResponses
          (malformed <> "-ASK 10 127.0.0.1:6382\r\n")
          BS.empty

    it "fails closed for a malformed streamed value rather than resynchronizing in its payload" $ do
      let malformed = "$?\r\n;not-a-length\r\n-MOVED 3999 redis.example:6381\r\n"
      parsePinnedResponses BS.empty malformed
        `shouldBe` PinnedResponseMalformed BS.empty

    it "allows framing overhead for an exact bulk payload limit and rejects the next payload byte" $ do
      let limit = 5
          acceptedPrefix = "$5\r\nabcde\r"
          acceptedSuffix = "\n"
          rejected = "$6\r\nabcdef\r"
      parsePinnedResponsesWithLimit limit BS.empty acceptedPrefix
        `shouldBe` PinnedResponses BS.empty acceptedPrefix
      parsePinnedResponsesWithLimit limit acceptedPrefix acceptedSuffix
        `shouldBe` PinnedResponses "$5\r\nabcde\r\n" BS.empty
      parsePinnedResponsesWithLimit limit BS.empty rejected
        `shouldBe` PinnedResponseLimitExceeded BS.empty

commandFrame :: [BS.ByteString] -> RespData
commandFrame = RespArray . fmap RespBulkString

encodeFrame :: RespData -> BS.ByteString
encodeFrame = LBS.toStrict . Builder.toLazyByteString . encode

assertSplitFrame :: RespData -> BS.ByteString -> Int -> Expectation
assertSplitFrame expected wire splitAt = do
  (frames, remainder) <- foldM consume ([], BS.empty) [BS.take splitAt wire, BS.drop splitAt wire]
  frames `shouldBe` [expected]
  remainder `shouldBe` BS.empty
  where
    consume (frames, pending) chunk =
      case parseSmartProxyFrames pending chunk of
        SmartProxyFrames newFrames nextPending -> pure (frames <> newFrames, nextPending)
        SmartProxyFrameError _ err             -> expectationFailure err >> error "unreachable"

streamedBlob :: [BS.ByteString] -> BS.ByteString
streamedBlob chunks =
  "$?\r\n" <> foldMap chunk chunks <> ";0\r\n"
  where
    chunk bytes = ";" <> BS8.pack (show $ BS.length bytes) <> "\r\n" <> bytes <> "\r\n"

assertPinnedResponseAcrossSplits :: BS.ByteString -> BS.ByteString -> Expectation
assertPinnedResponseAcrossSplits wire expected =
  mapM_ assertSplit [1 .. BS.length wire - 1]
  where
    assertSplit splitAt =
      case parsePinnedResponses BS.empty (BS.take splitAt wire) of
        PinnedResponses firstOutput pending ->
          case parsePinnedResponses pending (BS.drop splitAt wire) of
            PinnedResponses secondOutput remainder -> do
              (firstOutput <> secondOutput) `shouldBe` expected
              remainder `shouldBe` BS.empty
            result -> expectationFailure $ "response framing failed after split " <> show splitAt <> ": " <> show result
        result -> expectationFailure $ "response framing failed at split " <> show splitAt <> ": " <> show result

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
