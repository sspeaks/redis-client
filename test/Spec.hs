{-# LANGUAGE OverloadedStrings #-}

module Main where

import Test.Hspec
import Data.ByteString.Char8 qualified as B
import Resp

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