{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel           (PinnedProxyLogEntry (..),
                                          PinnedProxyLogMode (..),
                                          PinnedRequest (..),
                                          PinnedResponseResult (..),
                                          SmartProxyFrameResult (..),
                                          emitPinnedProxyTrafficLog,
                                          initialPinnedRequestScanner,
                                          parsePinnedResponses,
                                          parsePinnedResponsesWithLimit,
                                          parseSmartProxyFrames,
                                          scanPinnedRequests,
                                          smartProxyFrameLimit)
import           Control.Monad           (foldM, forM_)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8   as BS8
import qualified Data.ByteString.Lazy    as LBS
import           Data.IORef              (modifyIORef', newIORef, readIORef)
import           Data.List               (isInfixOf)
import           Database.Redis.Cluster  (NodeAddress (..))
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

  describe "pinned request-aware rewriting" $ do
    it "does not modify GET values that look like hosts, addresses, or CLUSTER NODES text" $ do
      let values =
            [ "$4\r\nv1.2\r\n"
            , "$9\r\n10.0.0.12\r\n"
            , "$20\r\nredis1.example.local\r\n"
            , "$25\r\nnode-a 10.0.0.1:6379@1637\r\n"
            , "*2\r\n$8\r\n10.0.0.1\r\n$6\r\nk v:co\r\n"
            ]
      forM_ values $ \reply ->
        parsePinnedResponses [PinnedOtherRequest] BS.empty reply
          `shouldBe` (PinnedResponses reply BS.empty, 1)

    it "does not modify unanswered replies such as Pub/Sub messages" $ do
      let message = "*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$8\r\n10.0.0.1\r\n"
      parsePinnedResponses [] BS.empty message
        `shouldBe` (PinnedResponses message BS.empty, 0)
      parsePinnedResponses [PinnedStopTracking] BS.empty message
        `shouldBe` (PinnedResponses message BS.empty, 1)

    it "forwards non-topology RESP3 maps and sets byte-for-byte" $ do
      let respMap = "%2\r\n+z\r\n:1\r\n+a\r\n:2\r\n"
          respSet = "~2\r\n+z\r\n+a\r\n"
      parsePinnedResponses [PinnedOtherRequest, PinnedOtherRequest] BS.empty (respMap <> respSet)
        `shouldBe` (PinnedResponses (respMap <> respSet) BS.empty, 2)

    it "rewrites CLUSTER SLOTS node endpoints only" $ do
      let reply = encodeFrame $ RespArray
            [ RespArray
                [ RespInteger 0
                , RespInteger 5460
                , RespArray [RespBulkString "10.0.0.1", RespInteger 6379, RespBulkString "id-1"]
                , RespArray [RespBulkString "redis2.example", RespInteger 6380, RespBulkString "10.0.0.9"]
                , RespArray [RespBulkString "?", RespInteger 6381, RespBulkString "id-3"]
                ]
            ]
          expected = encodeFrame $ RespArray
            [ RespArray
                [ RespInteger 0
                , RespInteger 5460
                , RespArray [RespBulkString "127.0.0.1", RespInteger 6379, RespBulkString "id-1"]
                , RespArray [RespBulkString "127.0.0.1", RespInteger 6380, RespBulkString "10.0.0.9"]
                , RespArray [RespBulkString "?", RespInteger 6381, RespBulkString "id-3"]
                ]
            ]
      parsePinnedResponses [PinnedClusterSlots] BS.empty reply
        `shouldBe` (PinnedResponses expected BS.empty, 1)

    it "rewrites CLUSTER NODES text" $ do
      let text = "abc 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460\n"
          rewritten = "abc 127.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460\n"
      parsePinnedResponses [PinnedClusterNodes] BS.empty (encodeFrame $ RespBulkString text)
        `shouldBe` (PinnedResponses (encodeFrame $ RespBulkString rewritten) BS.empty, 1)

    it "rewrites CLUSTER SHARDS endpoint fields only" $ do
      let shard endpoint ip hostname = RespArray
            [ RespBulkString "slots"
            , RespArray [RespInteger 0, RespInteger 5460]
            , RespBulkString "nodes"
            , RespArray
                [ RespArray
                    [ RespBulkString "id", RespBulkString "10.0.0.7"
                    , RespBulkString "port", RespInteger 6379
                    , RespBulkString "ip", RespBulkString ip
                    , RespBulkString "endpoint", RespBulkString endpoint
                    , RespBulkString "hostname", RespBulkString hostname
                    ]
                ]
            ]
      parsePinnedResponses
        [PinnedClusterShards]
        BS.empty
        (encodeFrame $ RespArray [shard "10.0.0.1" "10.0.0.1" "redis1.example"])
        `shouldBe`
          ( PinnedResponses
              (encodeFrame $ RespArray [shard "127.0.0.1" "127.0.0.1" "127.0.0.1"])
              BS.empty
          , 1
          )

    it "matches pipelined replies with their requests in order" $ do
      let value = "$8\r\n10.0.0.1\r\n"
          nodes = encodeFrame $ RespBulkString "abc 10.0.0.1:6379@16379 master\n"
          rewrittenNodes = encodeFrame $ RespBulkString "abc 127.0.0.1:6379@16379 master\n"
      parsePinnedResponses
        [PinnedOtherRequest, PinnedClusterNodes, PinnedOtherRequest]
        BS.empty
        (value <> nodes <> value)
        `shouldBe` (PinnedResponses (value <> rewrittenNodes <> value) BS.empty, 3)

    it "rewrites MOVED and ASK for any request" $ do
      parsePinnedResponses [PinnedOtherRequest] BS.empty "-MOVED 3999 redis.example:6381\r\n"
        `shouldBe` (PinnedResponses "-MOVED 3999 127.0.0.1:6381\r\n" BS.empty, 1)
      parsePinnedResponses [] BS.empty "-ASK 10 10.0.0.2:6382\r\n"
        `shouldBe` (PinnedResponses "-ASK 10 127.0.0.1:6382\r\n" BS.empty, 0)

    it "forwards other error replies byte-for-byte" $ do
      let wrongType = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
      parsePinnedResponses [PinnedOtherRequest] BS.empty wrongType
        `shouldBe` (PinnedResponses wrongType BS.empty, 1)

  describe "pinned request scanning" $ do
    it "classifies topology requests case-insensitively and other requests as other" $ do
      let wire = encodeFrame (commandFrame ["cluster", "slots"])
            <> encodeFrame (commandFrame ["CLUSTER", "Nodes"])
            <> encodeFrame (commandFrame ["CLUSTER", "SHARDS"])
            <> encodeFrame (commandFrame ["GET", "CLUSTER"])
            <> encodeFrame (commandFrame ["CLUSTER", "INFO"])
      fst (scanPinnedRequests initialPinnedRequestScanner wire)
        `shouldBe`
          [ PinnedClusterSlots
          , PinnedClusterNodes
          , PinnedClusterShards
          , PinnedOtherRequest
          , PinnedOtherRequest
          ]

    it "classifies requests split at every byte boundary exactly once" $ do
      let wire = encodeFrame (commandFrame ["SET", "key", BS.replicate 300 120])
            <> encodeFrame (commandFrame ["CLUSTER", "SLOTS"])
      forM_ [1 .. BS.length wire - 1] $ \splitAt -> do
        let (first, scanner) = scanPinnedRequests initialPinnedRequestScanner (BS.take splitAt wire)
        case scanner of
          Nothing -> expectationFailure $ "tracking stopped at split " <> show splitAt
          Just continued ->
            (first <> fst (scanPinnedRequests continued (BS.drop splitAt wire)))
              `shouldBe` [PinnedOtherRequest, PinnedClusterSlots]

    it "stops tracking for Pub/Sub, MONITOR, CLIENT REPLY, and inline commands" $ do
      forM_
        [ encodeFrame (commandFrame ["SUBSCRIBE", "channel"])
        , encodeFrame (commandFrame ["monitor"])
        , encodeFrame (commandFrame ["CLIENT", "REPLY", "OFF"])
        , "PING\r\n"
        ] $ \wire -> do
          let (requests, scanner) =
                scanPinnedRequests initialPinnedRequestScanner
                  (encodeFrame (commandFrame ["PING"]) <> wire <> encodeFrame (commandFrame ["CLUSTER", "SLOTS"]))
          requests `shouldBe` [PinnedOtherRequest, PinnedStopTracking]
          maybe True (const False) scanner `shouldBe` True

  describe "pinned response TCP framing" $ do
    it "retains fragmented topology frames and rewrites only after completion" $ do
      let response = "-MOVED 3999 redis.example:6381\r\n"
          (firstChunk, secondChunk) = BS.splitAt 12 response
      framing BS.empty firstChunk
        `shouldBe` PinnedResponses BS.empty firstChunk
      framing firstChunk secondChunk
        `shouldBe` PinnedResponses "-MOVED 3999 127.0.0.1:6381\r\n" BS.empty

    it "drains coalesced replies in order and preserves untouched binary bytes" $ do
      let binary = "$5\r\n\NUL\255\r\n*\r\n"
          responses = "-ASK 10 redis.example:6382\r\n" <> binary <> "+OK\r\n"
      framing BS.empty responses
        `shouldBe` PinnedResponses
          ("-ASK 10 127.0.0.1:6382\r\n" <> binary <> "+OK\r\n")
          BS.empty

    it "passes unsupported RESP3 push bytes through without blocking" $ do
      let push = ">2\r\n+message\r\n+payload\r\n"
      framing BS.empty push
        `shouldBe` PinnedResponses push BS.empty

    it "preserves fragmented RESP3 pushes while rewriting later coalesced topology frames" $ do
      let push = ">2\r\n+message\r\n+payload\r\n"
          moved = "-MOVED 3999 redis.example:6381\r\n"
          (firstChunk, secondChunk) = BS.splitAt 11 (push <> moved)
      framing BS.empty firstChunk
        `shouldBe` PinnedResponses BS.empty firstChunk
      framing firstChunk secondChunk
        `shouldBe` PinnedResponses
          (push <> "-MOVED 3999 127.0.0.1:6381\r\n")
          BS.empty

    it "preserves a streamed blob payload exactly before rewriting a later response" $ do
      let payload = "x\n-MOVED 3999 redis.example:6381\r\n\NUL\255\n-ASK 10 redis.example:6382\r\n"
          stream = streamedBlob [payload]
          moved = "-MOVED 3999 redis.example:6381\r\n"
          expected = stream <> "-MOVED 3999 127.0.0.1:6381\r\n"
      framing BS.empty (stream <> moved)
        `shouldBe` PinnedResponses expected BS.empty
      assertPinnedResponseAcrossSplits (stream <> moved) expected

    it "frames nested streamed aggregates and multiple chunks before later rewrites" $ do
      let blob = streamedBlob ["first\n", "-ASK 10 redis.example:6382\r\n"]
          nested = "*?\r\n" <> blob <> ">?\r\n+message\r\n" <> streamedBlob ["payload"] <> ".\r\n.\r\n"
          ask = "-ASK 10 redis.example:6382\r\n"
          expected = nested <> "-ASK 10 127.0.0.1:6382\r\n"
      framing BS.empty (nested <> ask)
        `shouldBe` PinnedResponses expected BS.empty
      assertPinnedResponseAcrossSplits (nested <> ask) expected

    it "resumes framing after an opaque malformed record without swallowing later rewrites" $ do
      let malformed = "?bad\r\n"
          ask = "-ASK 10 redis.example:6382\r\n"
      framing BS.empty (malformed <> ask)
        `shouldBe` PinnedResponses
          (malformed <> "-ASK 10 127.0.0.1:6382\r\n")
          BS.empty

    it "fails closed for a malformed streamed value rather than resynchronizing in its payload" $ do
      let malformed = "$?\r\n;not-a-length\r\n-MOVED 3999 redis.example:6381\r\n"
      framing BS.empty malformed
        `shouldBe` PinnedResponseMalformed BS.empty

    it "allows framing overhead for an exact bulk payload limit and rejects the next payload byte" $ do
      let limit = 5
          acceptedPrefix = "$5\r\nabcde\r"
          acceptedSuffix = "\n"
          rejected = "$6\r\nabcdef\r"
      framingWithLimit limit BS.empty acceptedPrefix
        `shouldBe` PinnedResponses BS.empty acceptedPrefix
      framingWithLimit limit acceptedPrefix acceptedSuffix
        `shouldBe` PinnedResponses "$5\r\nabcde\r\n" BS.empty
      framingWithLimit limit BS.empty rejected
        `shouldBe` PinnedResponseLimitExceeded BS.empty

  describe "pinned proxy traffic logging" $ do
    it "suppresses per-request payload logging by default" $ do
      observed <- captureTrafficLogs PinnedProxyLifecycleOnly "client->redis" pingFrame
      observed `shouldBe` []

    it "emits preview-only traffic logs without forcing a flush in verbose mode" $ do
      observed <- captureTrafficLogs PinnedProxyVerboseTraffic "redis->client" movedFrame
      case observed of
        [PinnedProxyLogEntry message shouldFlush] -> do
          shouldFlush `shouldBe` False
          message `shouldSatisfy` isInfixOf "redis->client"
          message `shouldSatisfy` isInfixOf "preview="
          message `shouldSatisfy` isInfixOf "MOVED 3999 redis.example:6381"
        _ -> expectationFailure $ "unexpected traffic log output: " <> show observed

commandFrame :: [BS.ByteString] -> RespData
commandFrame = RespArray . fmap RespBulkString

encodeFrame :: RespData -> BS.ByteString
encodeFrame = LBS.toStrict . Builder.toLazyByteString . encode

loggingNodeAddress :: NodeAddress
loggingNodeAddress = NodeAddress "redis.example" 6381

pingFrame :: BS.ByteString
pingFrame = encodeFrame $ commandFrame ["PING"]

movedFrame :: BS.ByteString
movedFrame = "-MOVED 3999 redis.example:6381\r\n"

captureTrafficLogs :: PinnedProxyLogMode -> String -> BS.ByteString -> IO [PinnedProxyLogEntry]
captureTrafficLogs mode direction payload = do
  observed <- newIORef []
  emitPinnedProxyTrafficLog
    mode
    (\entry -> modifyIORef' observed (<> [entry]))
    loggingNodeAddress
    direction
    payload
  readIORef observed

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
      case framing BS.empty (BS.take splitAt wire) of
        PinnedResponses firstOutput pending ->
          case framing pending (BS.drop splitAt wire) of
            PinnedResponses secondOutput remainder -> do
              (firstOutput <> secondOutput) `shouldBe` expected
              remainder `shouldBe` BS.empty
            result -> expectationFailure $ "response framing failed after split " <> show splitAt <> ": " <> show result
        result -> expectationFailure $ "response framing failed at split " <> show splitAt <> ": " <> show result

-- | Framing with no tracked requests: only MOVED/ASK are rewritten.
framing :: BS.ByteString -> BS.ByteString -> PinnedResponseResult
framing pending chunk = fst (parsePinnedResponses [] pending chunk)

framingWithLimit :: Int -> BS.ByteString -> BS.ByteString -> PinnedResponseResult
framingWithLimit limit pending chunk = fst (parsePinnedResponsesWithLimit limit [] pending chunk)
