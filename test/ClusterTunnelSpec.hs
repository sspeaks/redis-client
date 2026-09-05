{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           ClusterTunnel                   (rewriteClusterResponse,
                                                  routeSmartProxyCommandWith)
import qualified Data.ByteString.Char8           as BS8
import           Data.IORef                      (IORef, newIORef, readIORef,
                                                  writeIORef)
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommandResp,
                                                  commandSourceSha,
                                                  commandSpecCount)
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

  describe "generated smart-proxy routing metadata" $ do
    it "pins a non-empty immutable redis-doc SHA and command count" $ do
      commandSourceSha `shouldBe` "928bf6ed9848b76b53429adf81f96f9db3b06800"
      commandSpecCount `shouldSatisfy` (> 50)

  describe "command classification" $ do
    it "rejects unsupported subcommands locally" $ do
      classifyCommandResp (resp ["MEMORY", "BOGUS"]) `shouldSatisfy` isError
      classifyCommandResp (resp ["CLIENT", "BOGUS"]) `shouldSatisfy` isError

    it "rejects malformed and invalid grammar commands locally" $ do
      classifyCommandResp (resp ["MSETNX", "k", "v", "dangling"])
        `shouldSatisfy` isError
      classifyCommandResp (resp ["XREAD", "NOACK", "STREAMS", "k", "0-0"])
        `shouldSatisfy` isError

    it "routes later-key and movable-key forms" $ do
      classifyCommandResp (resp ["EVAL", "return 1", "1", "{slot}k", "arg"])
        `shouldBe` KeyedRoute "{slot}k"
      classifyCommandResp (resp ["XREAD", "COUNT", "1", "STREAMS", "{slot}k", "0-0"])
        `shouldBe` KeyedRoute "{slot}k"
      classifyCommandResp (resp ["XREADGROUP", "GROUP", "g", "c", "COUNT", "1", "STREAMS", "{slot}k", ">"])
        `shouldBe` KeyedRoute "{slot}k"

    it "supports keyless commands that carry arguments" $ do
      classifyCommandResp (resp ["ECHO", "hello"])
        `shouldBe` KeylessRoute

    it "handles binary keys and validates slot locality" $ do
      classifyCommandResp (RespArray [RespBulkString "GET", RespBulkString "\NUL\255k"])
        `shouldBe` KeyedRoute "\NUL\255k"
      classifyCommandResp (resp ["MGET", "{a}k1", "{a}k2"])
        `shouldBe` KeyedRoute "{a}k1"
      classifyCommandResp (resp ["MGET", "{a}k1", "{b}k2"])
        `shouldSatisfy` isError

  describe "smart proxy no-contact guardrails" $ do
    it "never dispatches unknown, malformed, or cross-slot commands" $ do
      keylessCalls <- newIORef (0 :: Int)
      keyedCalls <- newIORef (0 :: Int)
      let keyless _ = bump keylessCalls >> pure (Right (RespSimpleString "OK"))
          keyed _ _ = bump keyedCalls >> pure (Right (RespSimpleString "OK"))
          runOne cmd =
            routeSmartProxyCommandWith classifyCommandResp keyless keyed "raw" cmd

      _ <- runOne (resp ["MEMORY", "BOGUS"])
      _ <- runOne (resp ["CLIENT", "BOGUS"])
      _ <- runOne (resp ["MSETNX", "k", "v", "odd"])
      _ <- runOne (resp ["MGET", "{a}k1", "{b}k2"])

      readIORef keylessCalls `shouldReturn` 0
      readIORef keyedCalls `shouldReturn` 0

  describe "raw frame identity through dispatch recorder" $ do
    it "preserves raw frames for success, MOVED, ASK, TRYAGAIN, Redis error, and transport error paths" $ do
      let rawFrame = "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n"
          cmd = resp ["GET", "foo"]
          scenarios =
            [ Right (RespBulkString "value")
            , Left "MovedError 1 (NodeAddress \"127.0.0.1\" 6380)"
            , Left "AskError 1 (NodeAddress \"127.0.0.1\" 6381)"
            , Left "TryAgainError \"TRYAGAIN pending\""
            , Left "RedisCommandError \"ERR ordinary\""
            , Left "ConnectionError \"transport dropped\""
            ]

      mapM_
        (\expected -> do
          recorded <- newIORef ""
          let keyless _ = pure (Left "unexpected keyless")
              keyed _ raw = writeIORef recorded raw >> pure expected
          _ <- routeSmartProxyCommandWith classifyCommandResp keyless keyed rawFrame cmd
          readIORef recorded `shouldReturn` rawFrame)
        scenarios

isError :: CommandRouting -> Bool
isError (CommandError _) = True
isError _                = False

bump :: IORef Int -> IO ()
bump ref = do
  n <- readIORef ref
  writeIORef ref (n + 1)

resp :: [String] -> RespData
resp = RespArray . map (RespBulkString . BS8.pack)
