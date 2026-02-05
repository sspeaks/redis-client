{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.ByteString qualified as BS
import Test.Hspec
import Data.Word (Word64)
import FillHelpers (generateBytes, generateBytesWithHashTag, randomNoise)

main :: IO ()
main = hspec $ do
  describe "FillHelpers byte generation" $ do
    describe "generateBytes" $ do
      it "generates correct size for small keys (1 byte)" $ do
        let result = Builder.toLazyByteString $ generateBytes 1 12345
        LB.length result `shouldBe` 1

      it "generates correct size for small keys (8 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 8 12345
        LB.length result `shouldBe` 8

      it "generates correct size for medium keys (128 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 128 12345
        LB.length result `shouldBe` 128

      it "generates correct size for default keys (512 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 512 12345
        LB.length result `shouldBe` 512

      it "generates correct size for large keys (2048 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 2048 12345
        LB.length result `shouldBe` 2048

      it "generates correct size for very large keys (8192 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 8192 12345
        LB.length result `shouldBe` 8192

      it "generates different content for different seeds" $ do
        let result1 = Builder.toLazyByteString $ generateBytes 512 12345
        let result2 = Builder.toLazyByteString $ generateBytes 512 54321
        result1 `shouldNotBe` result2

      it "generates same content for same seed" $ do
        let result1 = Builder.toLazyByteString $ generateBytes 512 12345
        let result2 = Builder.toLazyByteString $ generateBytes 512 12345
        result1 `shouldBe` result2

    describe "generateBytesWithHashTag" $ do
      it "generates correct size with hash tag" $ do
        let result = Builder.toLazyByteString $ generateBytesWithHashTag 512 "slot0" 12345
        LB.length result `shouldBe` 512

      it "includes hash tag in output" $ do
        let result = LB.toStrict $ Builder.toLazyByteString $ generateBytesWithHashTag 512 "slot0" 12345
        -- Check that the hash tag format {slot0}: appears in the key
        BS.take 8 result `shouldBe` "{slot0}:"

      it "falls back to regular generation for empty hash tag" $ do
        let result1 = Builder.toLazyByteString $ generateBytesWithHashTag 512 "" 12345
        let result2 = Builder.toLazyByteString $ generateBytes 512 12345
        result1 `shouldBe` result2

    describe "Key size validation" $ do
      it "minimum key size is 1 byte" $ do
        let result = Builder.toLazyByteString $ generateBytes 1 0
        LB.length result `shouldBe` 1

      it "supports maximum key size of 65536 bytes" $ do
        let result = Builder.toLazyByteString $ generateBytes 65536 0
        LB.length result `shouldBe` 65536

    describe "randomNoise buffer" $ do
      it "has expected size of 128 MB" $ do
        BS.length randomNoise `shouldBe` (128 * 1024 * 1024)
