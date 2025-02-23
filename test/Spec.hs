{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as B
import Data.Map qualified as M
import Data.Set qualified as S
import Resp
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "encode" $ do
    it "encodes simple strings correctly" $ do
      (Builder.toLazyByteString $ encode (RespSimpleString "OK")) `shouldBe` "+OK\r\n"
      (Builder.toLazyByteString $ encode (RespSimpleString "Hello")) `shouldBe` "+Hello\r\n"

    it "encodes errors correctly" $ do
      (Builder.toLazyByteString $ encode (RespError "Error message")) `shouldBe` "-Error message\r\n"
      (Builder.toLazyByteString $ encode (RespError "Another error")) `shouldBe` "-Another error\r\n"

    it "encodes integers correctly" $ do
      (Builder.toLazyByteString $ encode (RespInteger 123)) `shouldBe` ":123\r\n"
      (Builder.toLazyByteString $ encode (RespInteger 0)) `shouldBe` ":0\r\n"

    it "encodes bulk strings correctly" $ do
      (Builder.toLazyByteString $ encode (RespBulkString "foobar")) `shouldBe` "$6\r\nfoobar\r\n"
      (Builder.toLazyByteString $ encode (RespBulkString "")) `shouldBe` "$0\r\n\r\n"

    it "encodes arrays correctly" $ do
      (Builder.toLazyByteString $ encode (RespArray [RespSimpleString "foo", RespInteger 42])) `shouldBe` "*2\r\n+foo\r\n:42\r\n"
      (Builder.toLazyByteString $ encode (RespArray [])) `shouldBe` "*0\r\n"

    it "encodes maps correctly" $ do
      let mapData = M.fromList [(RespSimpleString "first", RespInteger 1), (RespSimpleString "second", RespBulkString "bulkString")]
      (Builder.toLazyByteString $ encode (RespMap mapData)) `shouldBe` "*2\r\n+first\r\n:1\r\n+second\r\n$10\r\nbulkString\r\n"
      (Builder.toLazyByteString $ encode (RespMap M.empty)) `shouldBe` "*0\r\n"

    it "encodes sets correctly" $ do
      let setData = S.fromList [(RespSimpleString "Hello"), (RespInteger 5), RespBulkString ("im very long")]
      (Builder.toLazyByteString $ encode (RespSet setData)) `shouldBe` "~3\r\n+Hello\r\n:5\r\n$12\r\nim very long\r\n"
      (Builder.toLazyByteString $ encode (RespSet S.empty)) `shouldBe` "~0\r\n"