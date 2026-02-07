{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LB
import Data.ByteString qualified as BS
import Test.Hspec
import Data.Word (Word64)
import FillHelpers (generateBytes, generateBytesWithHashTag, randomNoise)
import Filler (genRandomSet)

main :: IO ()
main = hspec $ do
  describe "Filler" $ do
    describe "genRandomSet" $ do
      it "generates correct number of commands based on batch size" $ do
        -- Batch size 10, key size 10, value size 10
        let batchSize = 10
            result = genRandomSet batchSize 10 10 12345
            -- Convert to strict for searching (safe for small test data)
            strictResult = LB.toStrict result
        
        -- Count occurrences of "*3\r\n$3\r\nSET\r\n" which marks the start of each SET command
        let count :: BS.ByteString -> Int
            count bs 
              | BS.null bs = 0
              | otherwise = 
                  let marker = "*3\r\n$3\r\nSET\r\n"
                      (_, after) = BS.breakSubstring marker bs
                  in if BS.null after 
                     then 0 
                     else 1 + count (BS.drop (BS.length marker) after)
                     
        count strictResult `shouldBe` batchSize

      it "output size scales with batch size" $ do
        let result1 = genRandomSet 10 10 10 12345
        let result2 = genRandomSet 20 10 10 12345
        -- Should be exactly double
        LB.length result2 `shouldBe` (2 * LB.length result1)

      it "generates valid RESP structure for batch size 1" $ do
        let keySize = 5
            valSize = 5
            -- Structure: *3\r\n$3\r\nSET\r\n$<keySize>\r\n<key>\r\n$<valSize>\r\n<val>\r\n
            -- Length = (4 + 4 + 5 + 1 + 1 + 2) + 5 + (2 + 1 + 1 + 2) + 5 + 2
            -- *3\r\n$3\r\nSET\r\n$5\r\n (17)
            -- key (5)
            -- \r\n$5\r\n (6)
            -- val (5)
            -- \r\n (2)
            -- Total: 35
            expectedLen = 35
            result = genRandomSet 1 5 5 12345
        LB.length result `shouldBe` expectedLen
        let bs = LB.toStrict result
        let expectedPrefix = Builder.toLazyByteString $ Builder.stringUtf8 "*3\r\n$3\r\nSET\r\n"
        LB.isPrefixOf expectedPrefix result `shouldBe` True

      it "handles large batch sizes correctly" $ do
        let result = genRandomSet 10000 10 10 12345
        LB.length result `shouldSatisfy` (> 0)

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

    describe "Value size support" $ do
      it "generates correct size for small values (128 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 128 12345
        LB.length result `shouldBe` 128

      it "generates correct size for default values (512 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 512 12345
        LB.length result `shouldBe` 512

      it "generates correct size for large values (8192 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 8192 12345
        LB.length result `shouldBe` 8192

      it "generates correct size for very large values (65536 bytes)" $ do
        let result = Builder.toLazyByteString $ generateBytes 65536 12345
        LB.length result `shouldBe` 65536

      it "supports maximum value size of 524288 bytes" $ do
        let result = Builder.toLazyByteString $ generateBytes 524288 12345
        LB.length result `shouldBe` 524288

    describe "Edge case sizes" $ do
      it "generates correct size for 0 bytes" $ do
        let result = Builder.toLazyByteString $ generateBytes 0 12345
        LB.length result `shouldBe` 0

      it "generates correct size for 7 bytes" $ do
        let result = Builder.toLazyByteString $ generateBytes 7 12345
        LB.length result `shouldBe` 7

      it "generates correct size for 9 bytes" $ do
        let result = Builder.toLazyByteString $ generateBytes 9 12345
        LB.length result `shouldBe` 9

    describe "Seed collision detection" $ do
      it "different seeds produce different bytes for same size" $ do
        let seeds = [0, 1, 2, 100, 999, 65535] :: [Word64]
            results = map (\s -> Builder.toLazyByteString $ generateBytes 64 s) seeds
            uniqueResults = length $ filter id [r1 /= r2 | (r1, i) <- zip results [0::Int ..], (r2, j) <- zip results [0..], i < j]
        -- All pairs should differ
        uniqueResults `shouldBe` length [(i,j) | i <- [0..length seeds - 1], j <- [0..length seeds - 1], i < j]
