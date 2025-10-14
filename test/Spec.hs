{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Attoparsec.ByteString.Char8 (parseOnly)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as B
import Data.Map qualified as M
import Data.Set qualified as S
import RedisCommandClient (wrapInRay)
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

  describe "command encoding" $ do
    it "encodes MGET commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["MGET", "key1", "key2"]))
        `shouldBe` "*3\r\n$4\r\nMGET\r\n$4\r\nkey1\r\n$4\r\nkey2\r\n"

    it "encodes ZADD commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["ZADD", "myzset", "1", "one", "2", "two"]))
        `shouldBe` "*6\r\n$4\r\nZADD\r\n$6\r\nmyzset\r\n$1\r\n1\r\n$3\r\none\r\n$1\r\n2\r\n$3\r\ntwo\r\n"

    it "encodes ZRANGE WITHSCORES commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["ZRANGE", "myzset", "0", "-1", "WITHSCORES"]))
        `shouldBe` "*5\r\n$6\r\nZRANGE\r\n$6\r\nmyzset\r\n$1\r\n0\r\n$2\r\n-1\r\n$10\r\nWITHSCORES\r\n"

    it "encodes DECR commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["DECR", "counter"]))
        `shouldBe` "*2\r\n$4\r\nDECR\r\n$7\r\ncounter\r\n"

    it "encodes PSETEX commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["PSETEX", "temp", "500", "value"]))
        `shouldBe` "*4\r\n$6\r\nPSETEX\r\n$4\r\ntemp\r\n$3\r\n500\r\n$5\r\nvalue\r\n"

    it "encodes HMGET commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["HMGET", "myhash", "field1", "field2"]))
        `shouldBe` "*4\r\n$5\r\nHMGET\r\n$6\r\nmyhash\r\n$6\r\nfield1\r\n$6\r\nfield2\r\n"

    it "encodes HEXISTS commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["HEXISTS", "myhash", "field1"]))
        `shouldBe` "*3\r\n$7\r\nHEXISTS\r\n$6\r\nmyhash\r\n$6\r\nfield1\r\n"

    it "encodes SCARD commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["SCARD", "myset"]))
        `shouldBe` "*2\r\n$5\r\nSCARD\r\n$5\r\nmyset\r\n"

    it "encodes SISMEMBER commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["SISMEMBER", "myset", "one"]))
        `shouldBe` "*3\r\n$9\r\nSISMEMBER\r\n$5\r\nmyset\r\n$3\r\none\r\n"

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