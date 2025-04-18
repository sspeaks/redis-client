{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Attoparsec.ByteString.Char8 (parseOnly)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as B
import Data.Map qualified as M
import Data.Set qualified as S
import Resp
import Test.Hspec

main :: IO ()
main = hspec $ describe "encode" $ do
  it "encodes simple strings correctly" $ do
    Builder.toLazyByteString (encode (RespSimpleString "OK")) `shouldBe` "+OK\r\n"
    Builder.toLazyByteString (encode (RespSimpleString "Hello")) `shouldBe` "+Hello\r\n"

  it "encodes errors correctly" $ do
    Builder.toLazyByteString (encode (RespError "Error message")) `shouldBe` "-Error message\r\n"
    Builder.toLazyByteString (encode (RespError "Another error")) `shouldBe` "-Another error\r\n"

  it "encodes integers correctly" $ do
    Builder.toLazyByteString (encode (RespInteger 123)) `shouldBe` ":123\r\n"
    Builder.toLazyByteString (encode (RespInteger 0)) `shouldBe` ":0\r\n"

  it "encodes bulk strings correctly" $ do
    Builder.toLazyByteString (encode (RespBulkString "foobar")) `shouldBe` "$6\r\nfoobar\r\n"
    Builder.toLazyByteString (encode (RespBulkString "")) `shouldBe` "$0\r\n\r\n"

  it "encodes arrays correctly" $ do
    Builder.toLazyByteString (encode (RespArray [RespSimpleString "foo", RespInteger 42])) `shouldBe` "*2\r\n+foo\r\n:42\r\n"
    Builder.toLazyByteString (encode (RespArray [])) `shouldBe` "*0\r\n"

  it "encodes maps correctly" $ do
    let mapData = M.fromList [(RespSimpleString "first", RespInteger 1), (RespSimpleString "second", RespBulkString "bulkString")]
    Builder.toLazyByteString (encode (RespMap mapData)) `shouldBe` "*2\r\n+first\r\n:1\r\n+second\r\n$10\r\nbulkString\r\n"
    Builder.toLazyByteString (encode (RespMap M.empty)) `shouldBe` "*0\r\n"

  it "encodes sets correctly" $ do
    let setData = S.fromList [RespSimpleString "Hello", RespInteger 5, RespBulkString "im very long"]
    Builder.toLazyByteString (encode (RespSet setData)) `shouldBe` "~3\r\n+Hello\r\n:5\r\n$12\r\nim very long\r\n"
    Builder.toLazyByteString (encode (RespSet S.empty)) `shouldBe` "~0\r\n"

  it "encodes lists of length greater than 10 correctly" $ do
    let longList = RespArray (replicate 11 (RespSimpleString "item"))
    Builder.toLazyByteString (encode longList) `shouldBe` "*11\r\n" <> mconcat (replicate 11 "+item\r\n")

  it "parses lists of length greater than 10 correctly" $ do
    let longListEncoded = "*11\r\n" <> mconcat (replicate 11 "+item\r\n")
    parseOnly parseRespData (B.toStrict longListEncoded) `shouldBe` Right (RespArray (replicate 11 (RespSimpleString "item")))

  describe "parse" $ do
    it "parses simple strings correctly" $ do
      parseOnly parseRespData "+OK\r\n" `shouldBe` Right (RespSimpleString "OK")
      parseOnly parseRespData "+Hello\r\n" `shouldBe` Right (RespSimpleString "Hello")

    it "parses errors correctly" $ do
      parseOnly parseRespData "-Error message\r\n" `shouldBe` Right (RespError "Error message")
      parseOnly parseRespData "-Another error\r\n" `shouldBe` Right (RespError "Another error")

    it "parses integers correctly" $ do
      parseOnly parseRespData ":123\r\n" `shouldBe` Right (RespInteger 123)
      parseOnly parseRespData ":0\r\n" `shouldBe` Right (RespInteger 0)

    it "parses bulk strings correctly" $ do
      parseOnly parseRespData "$6\r\nfoobar\r\n" `shouldBe` Right (RespBulkString "foobar")
      parseOnly parseRespData "$0\r\n\r\n" `shouldBe` Right (RespBulkString "")

    it "parses null bulk strings correctly" $ do
      parseOnly parseRespData "$-1\r\n" `shouldBe` Right RespNullBilkString

    it "parses arrays correctly" $ do
      parseOnly parseRespData "*2\r\n+foo\r\n:42\r\n" `shouldBe` Right (RespArray [RespSimpleString "foo", RespInteger 42])
      parseOnly parseRespData "*0\r\n" `shouldBe` Right (RespArray [])

    it "parses maps correctly" $ do
      let mapData = M.fromList [(RespSimpleString "first", RespInteger 1), (RespSimpleString "second", RespBulkString "bulkString")]
      parseOnly parseRespData "%2\r\n+first\r\n:1\r\n+second\r\n$10\r\nbulkString\r\n" `shouldBe` Right (RespMap mapData)
      parseOnly parseRespData "%0\r\n" `shouldBe` Right (RespMap M.empty)

    it "parses sets correctly" $ do
      let setData = S.fromList [RespSimpleString "Hello", RespInteger 5, RespBulkString "im very long"]
      parseOnly parseRespData "~3\r\n+Hello\r\n:5\r\n$12\r\nim very long\r\n" `shouldBe` Right (RespSet setData)
      parseOnly parseRespData "~0\r\n" `shouldBe` Right (RespSet S.empty)

    it "parses lists of length greater than 10 correctly" $ do
      let longListEncoded = "*11\r\n" <> mconcat (replicate 11 "+item\r\n")
      parseOnly parseRespData (B.toStrict longListEncoded) `shouldBe` Right (RespArray (replicate 11 (RespSimpleString "item")))