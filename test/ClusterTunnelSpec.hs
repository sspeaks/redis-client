{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel                         (rewriteClusterResponse,
                                                        routeSmartProxyCommand)
import           Control.Concurrent.MVar               (newMVar)
import           Control.Concurrent.STM                (newTVarIO)
import           Control.Monad.IO.Class                (liftIO)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Lazy                  as LBS
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import qualified Data.Map.Strict                       as Map
import           Data.Time.Clock                       (getCurrentTime)
import qualified Data.Vector                           as V
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..),
                                                        NodeRole (..),
                                                        SlotRange (..))
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterConfig (..))
import           Database.Redis.Cluster.Commands       (keyArguments,
                                                        keyArgumentsFromResp)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..),
                                                        createPool)
import           Database.Redis.Internal.MultiplexPool (createMultiplexPool)
import           Database.Redis.Resp                   (RespData (..))
import qualified Database.Redis.Resp                   as Resp
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
    it "matches the Redis 7.2.12 command metadata key specifications" $
      mapM_ assertKeys
        [ ("GET", ["key"], ["key"])
        , ("BITOP", ["AND", "destination", "source"], ["destination", "source"])
        , ("SINTERSTORE", ["destination", "source"], ["destination", "source"])
        , ("ZUNIONSTORE", ["{tag}:out", "2", "{tag}:one", "{tag}:two"],
            ["{tag}:out", "{tag}:one", "{tag}:two"])
        , ("MSET", ["{tag}:one", "one", "{tag}:two", "two"],
            ["{tag}:one", "{tag}:two"])
        , ("EVAL", ["return KEYS[1]", "1", "key", "argument"], ["key"])
        , ("XREADGROUP", ["GROUP", "g", "c", "STREAMS", "one", "two", ">", ">"],
            ["one", "two"])
        , ("MEMORY", ["USAGE", "key"], ["key"])
        , ("OBJECT", ["ENCODING", "key"], ["key"])
        , ("XINFO", ["STREAM", "stream", "FULL", "COUNT", "1"], ["stream"])
        , ("PFCOUNT", ["one", "two"], ["one", "two"])
        , ("TOUCH", ["one", "two"], ["one", "two"])
        , ("UNLINK", ["one", "two"], ["one", "two"])
        , ("WATCH", ["one", "two"], ["one", "two"])
        , ("BLPOP", ["one", "two", "0"], ["one", "two"])
        , ("GEORADIUS", ["source", "1", "2", "3", "km", "STORE", "destination"],
            ["source", "destination"])
        ]

    it "keeps keyless commands keyless when they have arguments" $
      keyArgumentsFromResp "ECHO" [RespInteger 42] `shouldBe` Right []

    it "preserves binary non-key RESP arguments for raw forwarding" $
      keyArgumentsFromResp "SET" [RespBulkString "key", RespBulkString "\NUL\255"]
        `shouldBe` Right ["key"]

    it "fails closed for unknown and malformed Redis 7.2.12 specifications" $ do
      keyArguments "MODULE.FUTURE" ["might-be-a-key"]
        `shouldBe` Left "unsupported command for cluster routing: MODULE.FUTURE"
      keyArguments "EVALSHA" ["digest", "not-a-number"]
        `shouldBe` Left "command EVALSHA has an invalid key count"
      keyArguments "ZUNION" ["2", "one"]
        `shouldBe` Left "command ZUNION has fewer keys than its key count"
      keyArguments "ZINTERCARD" ["2", "one"]
        `shouldBe` Left "command ZINTERCARD has fewer keys than its key count"
      keyArguments "EVAL" ["return 1", "2", "one"]
        `shouldBe` Left "command EVAL has fewer keys than its key count"
      keyArguments "MSET" ["key", "value", "orphan"]
        `shouldBe` Left "command MSET requires key-value pairs"
      keyArguments "BLPOP" ["0"]
        `shouldBe` Left "command BLPOP requires keys and a timeout"
      keyArguments "MEMORY" ["USAGE"]
        `shouldBe` Left "command MEMORY has an invalid subcommand or arity"
      keyArguments "XINFO" ["STREAM"]
        `shouldBe` Left "command XINFO has an invalid subcommand or arity"
      keyArguments "OBJECT" ["ENCODING"]
        `shouldBe` Left "command OBJECT has an invalid subcommand or arity"
      keyArguments "GEORADIUS" ["source", "1", "2", "3", "km", "STORE"]
        `shouldBe` Left "command has a STORE option without a destination key"

  describe "smart proxy dispatch" $ do
    it "does not contact a node for unknown, malformed, or cross-slot requests" $ do
      (client, connectionCount, _) <- mockClusterClient
      let unknown = RespArray [RespBulkString "MODULE.FUTURE", RespBulkString "key"]
          malformed = RespArray [RespBulkString "ZUNION", RespBulkString "2", RespBulkString "key"]
          malformedMemory = RespArray [RespBulkString "MEMORY", RespBulkString "USAGE"]
          malformedXInfo = RespArray [RespBulkString "XINFO", RespBulkString "STREAM"]
          oddMSet = RespArray [RespBulkString "MSET", RespBulkString "key",
            RespBulkString "value", RespBulkString "orphan"]
          timeoutOnly = RespArray [RespBulkString "BLPOP", RespBulkString "0"]
          crossSlot = RespArray [RespBulkString "MGET", RespBulkString "one", RespBulkString "two"]
      routeSmartProxyCommand client unknown "unknown" `shouldReturn`
        Left "unsupported command for cluster routing: MODULE.FUTURE"
      routeSmartProxyCommand client malformed "malformed" `shouldReturn`
        Left "command ZUNION has fewer keys than its key count"
      routeSmartProxyCommand client malformedMemory "memory" `shouldReturn`
        Left "command MEMORY has an invalid subcommand or arity"
      routeSmartProxyCommand client malformedXInfo "xinfo" `shouldReturn`
        Left "command XINFO has an invalid subcommand or arity"
      routeSmartProxyCommand client oddMSet "mset" `shouldReturn`
        Left "command MSET requires key-value pairs"
      routeSmartProxyCommand client timeoutOnly "blpop" `shouldReturn`
        Left "command BLPOP requires keys and a timeout"
      routeSmartProxyCommand client crossSlot "cross-slot" `shouldReturn`
        Left "CROSSSLOT Keys in request don't hash to the same slot"
      readIORef connectionCount `shouldReturn` 0

    it "forwards supported same-slot frames byte-for-byte through cluster handling" $ do
      (client, _, sent) <- mockClusterClient
      let rawFrame = "*3\r\n$3\r\nSET\r\n$7\r\n{tag}:a\r\n$1\r\nx\r\n"
      case Resp.parseStrict rawFrame of
        Left err -> expectationFailure err
        Right parsed -> do
          routeSmartProxyCommand client parsed rawFrame `shouldReturn`
            Right (RespSimpleString "OK")
          readIORef sent `shouldReturn` rawFrame

    it "rejects cross-slot keys from all Redis multi-key range specifications" $ do
      (client, connectionCount, _) <- mockClusterClient
      mapM_ (\command ->
        routeSmartProxyCommand client command "cross-slot" `shouldReturn`
          Left "CROSSSLOT Keys in request don't hash to the same slot")
        [ RespArray [RespBulkString "PFCOUNT", RespBulkString "one", RespBulkString "two"]
        , RespArray [RespBulkString "TOUCH", RespBulkString "one", RespBulkString "two"]
        , RespArray [RespBulkString "UNLINK", RespBulkString "one", RespBulkString "two"]
        , RespArray [RespBulkString "WATCH", RespBulkString "one", RespBulkString "two"]
        ]
      readIORef connectionCount `shouldReturn` 0

assertKeys :: (BS.ByteString, [BS.ByteString], [BS.ByteString]) -> Expectation
assertKeys (command, arguments, expectedKeys) =
  keyArguments command arguments `shouldBe` Right expectedKeys

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !(IORef BS.ByteString) -> !(IORef [BS.ByteString]) -> MockClient 'Connected

instance Client MockClient where
  connect = error "MockClient: connect not supported"
  close _ = pure ()
  send (MockConnected sent _) bytes =
    liftIO $ atomicModifyIORef' sent (\old -> (old <> LBS.toStrict bytes, ()))
  receive (MockConnected _ responses) = liftIO $ atomicModifyIORef' responses nextResponse
    where
      nextResponse (response:rest) = (rest, response)
      nextResponse []              = error "MockClient: response queue exhausted"

mockClusterClient :: IO (ClusterClient MockClient, IORef Int, IORef BS.ByteString)
mockClusterClient = do
  connectionCount <- newIORef 0
  sent <- newIORef BS.empty
  now <- getCurrentTime
  let address = NodeAddress "mock" 6379
      nodeId = "mock-node"
      node = ClusterNode nodeId address Master [SlotRange 0 16383 nodeId []] []
      topology = ClusterTopology
        (V.replicate 16384 nodeId) (V.replicate 16384 address)
        (Map.singleton nodeId node) now
      poolConfig = PoolConfig 1 5000 1 False
      config = ClusterConfig address poolConfig 1 0 600
      connector _ = do
        atomicModifyIORef' connectionCount (\n -> (n + 1, ()))
        responses <- newIORef ["+OK\r\n"]
        pure (MockConnected sent responses)
  topologyVar <- newTVarIO topology
  pool <- createPool poolConfig
  muxPool <- createMultiplexPool connector 1
  refreshLock <- newMVar ()
  pure (ClusterClient topologyVar pool config connector refreshLock muxPool, connectionCount, sent)
