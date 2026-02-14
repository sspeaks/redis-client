{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Attoparsec.ByteString.Char8 (parseOnly)
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as BS8
import qualified Data.ByteString.Lazy             as LBS
import           Data.Either                      (isLeft)
import qualified Data.Map                         as M
import qualified Data.Set                         as S
import           Database.Redis.Resp
import           RedisCommandClient               (wrapInRay)
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "RESP Encoding" $ do
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

    it "encodes negative integers correctly" $ do
      Builder.toLazyByteString (encode (RespInteger (-1))) `shouldBe` ":-1\r\n"
      Builder.toLazyByteString (encode (RespInteger (-999))) `shouldBe` ":-999\r\n"

    it "encodes null bulk strings correctly" $ do
      Builder.toLazyByteString (encode RespNullBulkString) `shouldBe` "$-1\r\n"

    it "encodes nested arrays correctly" $ do
      let nested = RespArray [RespArray [RespInteger 1, RespInteger 2], RespArray [RespInteger 3]]
      Builder.toLazyByteString (encode nested) `shouldBe` "*2\r\n*2\r\n:1\r\n:2\r\n*1\r\n:3\r\n"

    it "encodes large bulk strings correctly" $ do
      let bigStr = BS8.pack (replicate 1000 'A')
      Builder.toLazyByteString (encode (RespBulkString bigStr)) `shouldBe`
        "$1000\r\n" <> LBS.fromStrict bigStr <> "\r\n"

  describe "Redis Command Encoding" $ do
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

    it "encodes GEOADD commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEOADD", "locations", "13.361389", "38.115556", "Palermo"]))
        `shouldBe` "*5\r\n$6\r\nGEOADD\r\n$9\r\nlocations\r\n$9\r\n13.361389\r\n$9\r\n38.115556\r\n$7\r\nPalermo\r\n"

    it "encodes GEOHASH commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEOHASH", "locations", "Palermo", "Catania"]))
        `shouldBe` "*4\r\n$7\r\nGEOHASH\r\n$9\r\nlocations\r\n$7\r\nPalermo\r\n$7\r\nCatania\r\n"

    it "encodes GEOSEARCH commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEOSEARCH", "locations", "FROMLONLAT", "13", "38", "BYRADIUS", "50", "KM", "ASC"]))
        `shouldBe` "*9\r\n$9\r\nGEOSEARCH\r\n$9\r\nlocations\r\n$10\r\nFROMLONLAT\r\n$2\r\n13\r\n$2\r\n38\r\n$8\r\nBYRADIUS\r\n$2\r\n50\r\n$2\r\nKM\r\n$3\r\nASC\r\n"

    it "encodes GEODIST commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEODIST", "geo", "Palermo", "Catania", "KM"]))
        `shouldBe` "*5\r\n$7\r\nGEODIST\r\n$3\r\ngeo\r\n$7\r\nPalermo\r\n$7\r\nCatania\r\n$2\r\nKM\r\n"

    it "encodes GEOPOS commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEOPOS", "geo", "Palermo", "Catania"]))
        `shouldBe` "*4\r\n$6\r\nGEOPOS\r\n$3\r\ngeo\r\n$7\r\nPalermo\r\n$7\r\nCatania\r\n"

    it "encodes GEORADIUS commands with flags correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEORADIUS", "geo", "15.0", "37.0", "200.0", "KM", "WITHDIST", "ASC"]))
        `shouldBe` "*8\r\n$9\r\nGEORADIUS\r\n$3\r\ngeo\r\n$4\r\n15.0\r\n$4\r\n37.0\r\n$5\r\n200.0\r\n$2\r\nKM\r\n$8\r\nWITHDIST\r\n$3\r\nASC\r\n"

    it "encodes GEORADIUS_RO commands with flags correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEORADIUS_RO", "geo", "15.0", "37.0", "200.0", "KM", "WITHCOORD"]))
        `shouldBe` "*7\r\n$12\r\nGEORADIUS_RO\r\n$3\r\ngeo\r\n$4\r\n15.0\r\n$4\r\n37.0\r\n$5\r\n200.0\r\n$2\r\nKM\r\n$9\r\nWITHCOORD\r\n"

    it "encodes GEORADIUSBYMEMBER commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEORADIUSBYMEMBER", "geo", "Palermo", "200.0", "KM", "WITHDIST", "DESC"]))
        `shouldBe` "*7\r\n$17\r\nGEORADIUSBYMEMBER\r\n$3\r\ngeo\r\n$7\r\nPalermo\r\n$5\r\n200.0\r\n$2\r\nKM\r\n$8\r\nWITHDIST\r\n$4\r\nDESC\r\n"

    it "encodes GEORADIUSBYMEMBER_RO commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEORADIUSBYMEMBER_RO", "geo", "Palermo", "200.0", "KM", "COUNT", "5", "ANY"]))
        `shouldBe` "*8\r\n$20\r\nGEORADIUSBYMEMBER_RO\r\n$3\r\ngeo\r\n$7\r\nPalermo\r\n$5\r\n200.0\r\n$2\r\nKM\r\n$5\r\nCOUNT\r\n$1\r\n5\r\n$3\r\nANY\r\n"

    it "encodes GEOSEARCHSTORE commands with STOREDIST correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["GEOSEARCHSTORE", "dest", "src", "FROMMEMBER", "Palermo", "BYBOX", "100.0", "200.0", "KM", "DESC", "STOREDIST"]))
        `shouldBe` "*11\r\n$14\r\nGEOSEARCHSTORE\r\n$4\r\ndest\r\n$3\r\nsrc\r\n$10\r\nFROMMEMBER\r\n$7\r\nPalermo\r\n$5\r\nBYBOX\r\n$5\r\n100.0\r\n$5\r\n200.0\r\n$2\r\nKM\r\n$4\r\nDESC\r\n$9\r\nSTOREDIST\r\n"

    it "encodes CLIENT SETINFO commands correctly" $ do
      Builder.toLazyByteString (encode (wrapInRay ["CLIENT", "SETINFO", "LIB-NAME", "redis-client"]))
        `shouldBe` "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$12\r\nredis-client\r\n"

  describe "RESP Parsing" $ do
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
      parseOnly parseRespData "$-1\r\n" `shouldBe` Right RespNullBulkString

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
      parseOnly parseRespData (LBS.toStrict longListEncoded) `shouldBe` Right (RespArray (replicate 11 (RespSimpleString "item")))

    it "parses negative integers correctly" $ do
      parseOnly parseRespData ":-1\r\n" `shouldBe` Right (RespInteger (-1))
      parseOnly parseRespData ":-999\r\n" `shouldBe` Right (RespInteger (-999))

    it "parses null bulk strings and roundtrips correctly" $ do
      let encoded = Builder.toLazyByteString (encode RespNullBulkString)
      parseOnly parseRespData (LBS.toStrict encoded) `shouldBe` Right RespNullBulkString

    it "parses nested arrays correctly" $ do
      let nested = RespArray [RespArray [RespInteger 1, RespInteger 2], RespArray [RespInteger 3]]
          encoded = Builder.toLazyByteString (encode nested)
      parseOnly parseRespData (LBS.toStrict encoded) `shouldBe` Right nested

    it "parses empty collections correctly" $ do
      parseOnly parseRespData "*0\r\n" `shouldBe` Right (RespArray [])
      parseOnly parseRespData "%0\r\n" `shouldBe` Right (RespMap M.empty)
      parseOnly parseRespData "~0\r\n" `shouldBe` Right (RespSet S.empty)

    it "fails on incomplete RESP data" $ do
      parseOnly parseRespData "+OK" `shouldSatisfy` isLeft
      parseOnly parseRespData "$6\r\nfoo" `shouldSatisfy` isLeft
