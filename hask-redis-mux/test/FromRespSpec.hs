{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.ByteString         (ByteString)
import           Data.Either             (isLeft)
import           Data.Text               (Text)
import           Database.Redis.Command  (RedisClientError (..))
import           Database.Redis.FromResp (FromResp (..))
import           Database.Redis.Resp     (RespData (..))
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "FromResp RespData" $ do
    it "preserves successful RespData and rejects server errors" $ do
      fromResp (RespSimpleString "OK") `shouldBe` Right (RespSimpleString "OK")
      fromResp (RespInteger 42) `shouldBe` Right (RespInteger 42)
      fromResp RespNullBulkString `shouldBe` Right RespNullBulkString
      fromResp (RespBulkString "hello") `shouldBe` Right (RespBulkString "hello")
      fromResp (RespArray []) `shouldBe` Right (RespArray [])
      fromResp (RespError "ERR denied")
        `shouldBe`
          (Left (RedisServerError "ERR denied")
            :: Either RedisClientError RespData)

  describe "FromResp ByteString" $ do
    it "extracts RespBulkString payload" $ do
      fromResp (RespBulkString "hello") `shouldBe` (Right "hello" :: Either RedisClientError ByteString)

    it "extracts RespSimpleString payload" $ do
      fromResp (RespSimpleString "OK") `shouldBe` (Right "OK" :: Either RedisClientError ByteString)

    it "returns Left UnexpectedResp for wrong constructor" $ do
      let result = fromResp (RespInteger 42) :: Either RedisClientError ByteString
      result `shouldSatisfy` isLeft
      result `shouldBe` Left (RedisConversionError (RespInteger 42))

    it "returns Left UnexpectedResp for RespNullBulkString" $ do
      let result = fromResp RespNullBulkString :: Either RedisClientError ByteString
      result `shouldBe` Left (RedisConversionError RespNullBulkString)

  describe "FromResp (Maybe ByteString)" $ do
    it "returns Nothing for RespNullBulkString" $ do
      fromResp RespNullBulkString `shouldBe` (Right Nothing :: Either RedisClientError (Maybe ByteString))

    it "returns Just payload for RespBulkString" $ do
      fromResp (RespBulkString "val") `shouldBe` (Right (Just "val") :: Either RedisClientError (Maybe ByteString))

    it "returns Just payload for RespSimpleString" $ do
      fromResp (RespSimpleString "OK") `shouldBe` (Right (Just "OK") :: Either RedisClientError (Maybe ByteString))

    it "returns Left UnexpectedResp for wrong constructor" $ do
      let result = fromResp (RespInteger 1) :: Either RedisClientError (Maybe ByteString)
      result `shouldSatisfy` isLeft

  describe "FromResp Integer" $ do
    it "extracts RespInteger payload" $ do
      fromResp (RespInteger 42) `shouldBe` (Right 42 :: Either RedisClientError Integer)

    it "extracts negative integers" $ do
      fromResp (RespInteger (-1)) `shouldBe` (Right (-1) :: Either RedisClientError Integer)

    it "extracts zero" $ do
      fromResp (RespInteger 0) `shouldBe` (Right 0 :: Either RedisClientError Integer)

    it "returns Left UnexpectedResp for wrong constructor" $ do
      let result = fromResp (RespBulkString "42") :: Either RedisClientError Integer
      result `shouldBe` Left (RedisConversionError (RespBulkString "42"))

  describe "FromResp Bool" $ do
    it "interprets RespSimpleString OK as True" $ do
      fromResp (RespSimpleString "OK") `shouldBe` (Right True :: Either RedisClientError Bool)

    it "interprets RespInteger 1 as True" $ do
      fromResp (RespInteger 1) `shouldBe` (Right True :: Either RedisClientError Bool)

    it "interprets RespInteger 0 as False" $ do
      fromResp (RespInteger 0) `shouldBe` (Right False :: Either RedisClientError Bool)

    it "returns Left UnexpectedResp for other values" $ do
      let result = fromResp (RespBulkString "true") :: Either RedisClientError Bool
      result `shouldBe` Left (RedisConversionError (RespBulkString "true"))

    it "returns Left UnexpectedResp for non-OK simple string" $ do
      let result = fromResp (RespSimpleString "QUEUED") :: Either RedisClientError Bool
      result `shouldBe` Left (RedisConversionError (RespSimpleString "QUEUED"))

  describe "FromResp [ByteString]" $ do
    it "extracts array of bulk strings" $ do
      let input = RespArray [RespBulkString "a", RespBulkString "b"]
      fromResp input `shouldBe` (Right ["a", "b"] :: Either RedisClientError [ByteString])

    it "handles empty array" $ do
      fromResp (RespArray []) `shouldBe` (Right [] :: Either RedisClientError [ByteString])

    it "extracts array of simple strings" $ do
      let input = RespArray [RespSimpleString "x", RespSimpleString "y"]
      fromResp input `shouldBe` (Right ["x", "y"] :: Either RedisClientError [ByteString])

    it "returns Left UnexpectedResp for non-array" $ do
      let result = fromResp (RespBulkString "notarray") :: Either RedisClientError [ByteString]
      result `shouldSatisfy` isLeft

    it "returns Left when element is wrong type" $ do
      let input = RespArray [RespBulkString "a", RespInteger 1]
      let result = fromResp input :: Either RedisClientError [ByteString]
      result `shouldSatisfy` isLeft

  describe "FromResp [RespData]" $ do
    it "extracts array elements as RespData" $ do
      let input = RespArray [RespInteger 1, RespBulkString "two"]
      fromResp input `shouldBe` Right [RespInteger 1, RespBulkString "two"]

    it "handles empty array" $ do
      fromResp (RespArray []) `shouldBe` (Right [] :: Either RedisClientError [RespData])

    it "returns Left UnexpectedResp for non-array" $ do
      let result = fromResp (RespInteger 1) :: Either RedisClientError [RespData]
      result `shouldBe` Left (RedisConversionError (RespInteger 1))

  describe "FromResp ()" $ do
    it "always succeeds, discarding the response" $ do
      fromResp (RespSimpleString "OK") `shouldBe` (Right () :: Either RedisClientError ())
      fromResp (RespInteger 42) `shouldBe` (Right () :: Either RedisClientError ())
      fromResp RespNullBulkString `shouldBe` (Right () :: Either RedisClientError ())
      fromResp (RespArray []) `shouldBe` (Right () :: Either RedisClientError ())

    it "does not discard a Redis server error" $
      fromResp (RespError "ERR denied")
        `shouldBe` (Left (RedisServerError "ERR denied") :: Either RedisClientError ())

  describe "FromResp Text" $ do
    it "decodes UTF-8 bulk string to Text" $ do
      fromResp (RespBulkString "hello") `shouldBe` (Right "hello" :: Either RedisClientError Text)

    it "decodes UTF-8 simple string to Text" $ do
      fromResp (RespSimpleString "OK") `shouldBe` (Right "OK" :: Either RedisClientError Text)

    it "returns Left UnexpectedResp for invalid UTF-8" $ do
      let result = fromResp (RespBulkString "\xff\xfe") :: Either RedisClientError Text
      result `shouldSatisfy` isLeft

    it "returns Left UnexpectedResp for wrong constructor" $ do
      let result = fromResp (RespInteger 42) :: Either RedisClientError Text
      result `shouldBe` Left (RedisConversionError (RespInteger 42))

  describe "FromResp (Maybe Text)" $ do
    it "returns Nothing for RespNullBulkString" $ do
      fromResp RespNullBulkString `shouldBe` (Right Nothing :: Either RedisClientError (Maybe Text))

    it "returns Just text for valid UTF-8 bulk string" $ do
      fromResp (RespBulkString "hello") `shouldBe` (Right (Just "hello") :: Either RedisClientError (Maybe Text))

    it "returns Left UnexpectedResp for wrong constructor" $ do
      let result = fromResp (RespInteger 1) :: Either RedisClientError (Maybe Text)
      result `shouldSatisfy` isLeft
