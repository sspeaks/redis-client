{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import           Data.Time.Clock        (getCurrentTime)
import           Database.Redis.Cluster
import           Database.Redis.Resp    (RespData (..))
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "Hash tag extraction" $ do
    it "extracts hash tag from valid key" $ do
      extractHashTag "{user}:profile" `shouldBe` "user"
      extractHashTag "{user}:settings" `shouldBe` "user"
      extractHashTag "prefix{user}:profile" `shouldBe` "user"
      extractHashTag "prefix{user}" `shouldBe` "user"

    it "returns full key when no hash tag present" $ do
      extractHashTag "simple-key" `shouldBe` "simple-key"
      extractHashTag "key:with:colons" `shouldBe` "key:with:colons"

    it "uses only the first brace candidate" $ do
      extractHashTag "{first}{second}" `shouldBe` "first"
      extractHashTag "prefix{first}{second}" `shouldBe` "first"
      extractHashTag "prefix{}{second}" `shouldBe` "prefix{}{second}"
      extractHashTag "prefix{{first}}suffix" `shouldBe` "{first"

    it "falls back to the full key for empty or unmatched tags" $ do
      extractHashTag "{}" `shouldBe` "{}"
      extractHashTag "prefix{}suffix" `shouldBe` "prefix{}suffix"
      extractHashTag "{user" `shouldBe` "{user"
      extractHashTag "prefix{user" `shouldBe` "prefix{user"
      extractHashTag "user}" `shouldBe` "user}"

    it "handles special characters in hash tags" $ do
      extractHashTag "{user:1}" `shouldBe` "user:1"
      extractHashTag "{a-b}" `shouldBe` "a-b"
      extractHashTag "{tag.with.dots}" `shouldBe` "tag.with.dots"

    it "handles binary bytes without text decoding" $ do
      extractHashTag (BS.pack [0x00, 0x7b, 0xff, 0x7d, 0x01])
        `shouldBe` BS.singleton 0xff

  describe "Slot calculation" $ do
    it "matches Redis CLUSTER KEYSLOT vectors" $ do
      let vectors =
            [ ("simple-key", 6985),
              ("foo{bar}zap", 5061),
              ("{bar}zap", 5061),
              ("foo{}{bar}", 8363),
              ("foo{bar", 15278),
              ("foo}bar", 7223),
              ("foo{bar}{zap}", 5061),
              ("foo{{bar}}zap", 4015),
              ("a{tag}", 8338),
              ("b{tag}", 8338)
            ]
      mapM_ (\(key, slot) -> calculateSlot key `shouldBe` slot) vectors

    it "matches Redis CLUSTER KEYSLOT for binary keys" $ do
      calculateSlot (BS.pack [0x00, 0x7b, 0xff, 0x7d, 0x01])
        `shouldBe` 7920

    it "calculates same slot for keys with same hash tag" $ do
      let slot1 = calculateSlot "{user}:profile"
          slot2 = calculateSlot "{user}:settings"
      slot1 `shouldBe` slot2

    it "co-locates prefixed keys for multi-key routing" $ do
      calculateSlot "user:1{tenant}" `shouldBe` calculateSlot "user:2{tenant}"

    it "calculates different slots for different keys (usually)" $ do
      let slot1 = calculateSlot "key1"
          slot2 = calculateSlot "key2"
      -- Note: This could theoretically fail if both keys hash to same slot,
      -- but probability is very low
      slot1 `shouldNotBe` slot2

    it "handles empty key" $ do
      let slot = calculateSlot ""
      slot `shouldSatisfy` (< 16384)

    it "handles very long keys" $ do
      let longKey = BS8.replicate 1000 'x'
          slot = calculateSlot longKey
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
            Nothing     -> expectationFailure "Slot 0 should be assigned"
            Just nodeId -> nodeId `shouldNotBe` ""

    it "handles invalid responses" $ do
      currentTime <- getCurrentTime
      let invalidResponse = RespBulkString "invalid"
      case parseClusterSlots invalidResponse currentTime of
        Left _  -> return () -- Expected
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
            Nothing     -> expectationFailure "Slot 0 should be assigned"
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
