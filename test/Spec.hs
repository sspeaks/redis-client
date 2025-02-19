{-# LANGUAGE OverloadedStrings #-}

module Main where

import Test.Hspec
import Data.ByteString.Char8 qualified as B
import Resp
import Data.Map qualified as M
import Data.Set qualified as S

main :: IO ()
main = hspec $ do
  describe "encode" $ do
    it "encodes simple strings correctly" $ do
      encode (RespSimpleString "OK") `shouldBe` "+OK\r\n"
      encode (RespSimpleString "Hello") `shouldBe` "+Hello\r\n"

    it "encodes errors correctly" $ do
      encode (RespError "Error message") `shouldBe` "-Error message\r\n"
      encode (RespError "Another error") `shouldBe` "-Another error\r\n"

    it "encodes integers correctly" $ do
      encode (RespInteger 123) `shouldBe` ":123\r\n"
      encode (RespInteger 0) `shouldBe` ":0\r\n"

    it "encodes bulk strings correctly" $ do
      encode (RespBulkString "foobar") `shouldBe` "$6\r\nfoobar\r\n"
      encode (RespBulkString "") `shouldBe` "$0\r\n\r\n"

    it "encodes arrays correctly" $ do
      encode (RespArray [RespSimpleString "foo", RespInteger 42]) `shouldBe` "*2\r\n+foo\r\n:42\r\n"
      encode (RespArray []) `shouldBe` "*0\r\n"

    it "encodes maps correctly" $ do
      let mapData = M.fromList [(RespSimpleString "first", RespInteger 1), (RespSimpleString "second", RespBulkString "bulkString")]
      encode (RespMap mapData) `shouldBe` "*2\r\n+first\r\n:1\r\n+second\r\n$10\r\nbulkString\r\n"
      encode (RespMap M.empty) `shouldBe` "*0\r\n"
    
    it "encodes sets correctly" $ do
      let setData = S.fromList [(RespSimpleString "Hello"), (RespInteger 5), RespBulkString ("im very long")]
      encode (RespSet setData) `shouldBe` "~3\r\n+Hello\r\n:5\r\n$12\r\nim very long\r\n"
      encode (RespSet S.empty) `shouldBe` "~0\r\n"