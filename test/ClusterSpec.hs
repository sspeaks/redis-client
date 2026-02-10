{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Cluster
import qualified Data.ByteString.Char8 as BS8
import Data.Time.Clock (getCurrentTime)
import Resp (RespData (..))
import Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Hash tag extraction" $ do
    it "extracts hash tag from valid key" $ do
      extractHashTag "{user}:profile" `shouldBe` "user"
      extractHashTag "{user}:settings" `shouldBe` "user"

    it "returns full key when no hash tag present" $ do
      extractHashTag "simple-key" `shouldBe` "simple-key"
      extractHashTag "key:with:colons" `shouldBe` "key:with:colons"

    it "handles edge cases correctly" $ do
      -- Empty tag
      extractHashTag "{}" `shouldBe` "{}"
      -- No closing brace
      extractHashTag "{user" `shouldBe` "{user"
      -- No opening brace
      extractHashTag "user}" `shouldBe` "user}"
      -- Multiple braces - uses first valid pair
      extractHashTag "{first}{second}" `shouldBe` "first"
      -- Braces at end
      extractHashTag "key{tag}" `shouldBe` "key{tag}"

    it "handles special characters in hash tags" $ do
      extractHashTag "{user:1}" `shouldBe` "user:1"
      extractHashTag "{a-b}" `shouldBe` "a-b"
      extractHashTag "{tag.with.dots}" `shouldBe` "tag.with.dots"

  describe "Slot calculation" $ do
    it "calculates slot within valid range" $ do
      slot <- calculateSlot "test-key"
      slot `shouldSatisfy` (< 16384)

    it "calculates same slot for keys with same hash tag" $ do
      slot1 <- calculateSlot "{user}:profile"
      slot2 <- calculateSlot "{user}:settings"
      slot1 `shouldBe` slot2

    it "calculates different slots for different keys (usually)" $ do
      slot1 <- calculateSlot "key1"
      slot2 <- calculateSlot "key2"
      -- Note: This could theoretically fail if both keys hash to same slot,
      -- but probability is very low
      slot1 `shouldNotBe` slot2

    it "handles empty key" $ do
      slot <- calculateSlot ""
      slot `shouldSatisfy` (< 16384)

    it "handles very long keys" $ do
      let longKey = BS8.replicate 1000 'x'
      slot <- calculateSlot longKey
      slot `shouldSatisfy` (< 16384)

  describe "Topology parsing" $ do
    it "parses simple CLUSTER SLOTS response" $ do
      currentTime <- getCurrentTime
      let response =
            RespArray
              [ RespArray
                  [ RespInteger 0,
                    RespInteger 5460,
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7000,
                        RespBulkString "node-id-1"
                      ]
                  ]
              ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          -- Check that slots are assigned
          case findNodeForSlot topology 0 of
            Nothing -> expectationFailure "Slot 0 should be assigned"
            Just nodeId -> nodeId `shouldNotBe` ""

    it "handles invalid responses" $ do
      currentTime <- getCurrentTime
      let invalidResponse = RespBulkString "invalid"
      case parseClusterSlots invalidResponse currentTime of
        Left _ -> return () -- Expected
        Right _ -> expectationFailure "Should fail on invalid response"

    it "parses response with replicas" $ do
      currentTime <- getCurrentTime
      let response =
            RespArray
              [ RespArray
                  [ RespInteger 0,
                    RespInteger 5460,
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7000,
                        RespBulkString "master-1"
                      ],
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7003,
                        RespBulkString "replica-1"
                      ]
                  ]
              ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          -- Check that master is assigned
          case findNodeForSlot topology 0 of
            Nothing -> expectationFailure "Slot 0 should be assigned"
            Just nodeId -> nodeId `shouldNotBe` ""

  describe "Node lookup" $ do
    it "finds correct node for slot" $ do
      currentTime <- getCurrentTime
      let response =
            RespArray
              [ RespArray
                  [ RespInteger 0,
                    RespInteger 100,
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7000,
                        RespBulkString "node1"
                      ]
                  ],
                RespArray
                  [ RespInteger 101,
                    RespInteger 200,
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7001,
                        RespBulkString "node2"
                      ]
                  ]
              ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          findNodeForSlot topology 50 `shouldSatisfy` (/= Nothing)
          findNodeForSlot topology 150 `shouldSatisfy` (/= Nothing)
          -- Out of range
          findNodeForSlot topology 16384 `shouldBe` Nothing

    it "returns empty string for slots not covered by any node" $ do
      currentTime <- getCurrentTime
      let response =
            RespArray
              [ RespArray
                  [ RespInteger 0,
                    RespInteger 100,
                    RespArray
                      [ RespBulkString "127.0.0.1",
                        RespInteger 7000,
                        RespBulkString "node1"
                      ]
                  ]
              ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          findNodeForSlot topology 50 `shouldSatisfy` (/= Nothing)
          findNodeForSlot topology 200 `shouldBe` Just ""
