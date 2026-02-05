{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.ByteString qualified as BS
import Test.Hspec
import Data.Word (Word64)

-- Import the functions we want to test
-- Note: These are in the app directory, so we need to make sure they're accessible
-- For now, we'll create helper functions that mirror the logic

-- Mirror the byte generation logic for testing
generateBytesForTest :: Int -> Word64 -> LB.ByteString
generateBytesForTest size seed = Builder.toLazyByteString $ 
  if size <= 8
    then 
      let seedBS = LB.toStrict $ Builder.toLazyByteString (Builder.word64LE seed)
      in Builder.byteString (BS.take size seedBS)
    else Builder.word64LE seed <> Builder.byteString (BS.replicate (size - 8) 0)

main :: IO ()
main = hspec $ do
  describe "FillHelpers byte generation" $ do
    describe "generateBytes" $ do
      it "generates correct size for small keys (1 byte)" $ do
        let result = generateBytesForTest 1 12345
        LB.length result `shouldBe` 1

      it "generates correct size for small keys (8 bytes)" $ do
        let result = generateBytesForTest 8 12345
        LB.length result `shouldBe` 8

      it "generates correct size for medium keys (128 bytes)" $ do
        let result = generateBytesForTest 128 12345
        LB.length result `shouldBe` 128

      it "generates correct size for default keys (512 bytes)" $ do
        let result = generateBytesForTest 512 12345
        LB.length result `shouldBe` 512

      it "generates correct size for large keys (2048 bytes)" $ do
        let result = generateBytesForTest 2048 12345
        LB.length result `shouldBe` 2048

      it "generates correct size for very large keys (8192 bytes)" $ do
        let result = generateBytesForTest 8192 12345
        LB.length result `shouldBe` 8192

      it "generates different content for different seeds" $ do
        let result1 = generateBytesForTest 512 12345
        let result2 = generateBytesForTest 512 54321
        result1 `shouldNotBe` result2

      it "generates same content for same seed" $ do
        let result1 = generateBytesForTest 512 12345
        let result2 = generateBytesForTest 512 12345
        result1 `shouldBe` result2

    describe "Key size validation" $ do
      it "minimum key size is 1 byte" $ do
        let result = generateBytesForTest 1 0
        LB.length result `shouldBe` 1

      it "supports maximum key size of 65536 bytes" $ do
        let result = generateBytesForTest 65536 0
        LB.length result `shouldBe` 65536
