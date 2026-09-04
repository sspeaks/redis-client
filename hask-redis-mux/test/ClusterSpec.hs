{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Exception      (SomeException, evaluate, try)
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import           Data.Either            (isLeft)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (isJust)
import qualified Data.Set               as Set
import           Data.Time.Clock        (UTCTime, getCurrentTime)
import qualified Data.Vector            as V
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
    it "builds a complete topology with O(1) lookups" $ do
      currentTime <- getCurrentTime
      let response = clusterSlots
            [ slotRange 0 8191 (nodeRecord "127.0.0.1" 7000 "node-1") [],
              slotRange 8192 16383 (nodeRecord "redis-2.example" 7001 "node-2") []
            ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          V.length (topologySlots topology) `shouldBe` 16384
          V.length (topologyAddresses topology) `shouldBe` 16384
          Map.size (topologyNodes topology) `shouldBe` 2
          findNodeAddressForSlot topology 0 `shouldBe` Just (NodeAddress "127.0.0.1" 7000)
          findNodeAddressForSlot topology 8191 `shouldBe` Just (NodeAddress "127.0.0.1" 7000)
          findNodeAddressForSlot topology 8192 `shouldBe` Just (NodeAddress "redis-2.example" 7001)
          findNodeAddressForSlot topology 16383 `shouldBe` Just (NodeAddress "redis-2.example" 7001)
          mapM_
            (\slot -> findNodeForSlot topology slot `shouldSatisfy` isJust)
            [0 .. 16383]

    it "allows one node to own multiple disjoint ranges" $ do
      currentTime <- getCurrentTime
      let response = clusterSlots
            [ slotRange 0 100 (nodeRecord "127.0.0.1" 7000 "node-1") [],
              slotRange 101 16383 (nodeRecord "127.0.0.1" 7000 "node-1") []
            ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology ->
          case Map.lookup "node-1" (topologyNodes topology) of
            Nothing -> expectationFailure "node-1 was not recorded"
            Just node -> nodeSlotsServed node `shouldBe`
              [ SlotRange 0 100 "node-1" [],
                SlotRange 101 16383 "node-1" []
              ]

    it "parses response with replicas" $ do
      currentTime <- getCurrentTime
      let response = clusterSlots
            [ slotRange
                0
                16383
                (nodeRecord "127.0.0.1" 7000 "master-1")
                [nodeRecord "127.0.0.1" 7003 "replica-1"]
            ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          nodeReplicas (topologyNodes topology Map.! "master-1")
            `shouldBe` ["replica-1"]
          nodeRole (topologyNodes topology Map.! "replica-1")
            `shouldBe` Replica

    it "rejects negative, reversed, out-of-range, and overflow-sized ranges" $ do
      currentTime <- getCurrentTime
      let invalidRanges =
            [ slotRange (-1) 16383 validMaster [],
              slotRange 0 (-1) validMaster [],
              slotRange 10 9 validMaster [],
              slotRange 0 16384 validMaster [],
              slotRange 16384 16384 validMaster [],
              slotRange 0 (10 ^ (100 :: Int)) validMaster []
            ]
      mapM_
        (\entry ->
          parseClusterSlots (clusterSlots [entry]) currentTime
            `shouldSatisfy` isLeft)
        invalidRanges

    it "rejects ports outside the Redis TCP range before conversion" $ do
      currentTime <- getCurrentTime
      let invalidPorts = [-1, 0, 65536, 10 ^ (100 :: Int)]
      mapM_
        (\port ->
          shouldFailWith
            "port outside 1-65535"
            (clusterSlots [slotRange 0 16383 (nodeRecord "127.0.0.1" port "node-1") []])
            currentTime)
        invalidPorts

    it "accepts the minimum and maximum valid TCP ports" $ do
      currentTime <- getCurrentTime
      let response = clusterSlots
            [ slotRange 0 8191 (nodeRecord "127.0.0.1" 1 "node-low") [],
              slotRange 8192 16383 (nodeRecord "127.0.0.2" 65535 "node-high") []
            ]
      case parseClusterSlots response currentTime of
        Left err -> expectationFailure $ "Parsing failed: " ++ err
        Right topology -> do
          findNodeAddressForSlot topology 0
            `shouldBe` Just (NodeAddress "127.0.0.1" 1)
          findNodeAddressForSlot topology 16383
            `shouldBe` Just (NodeAddress "127.0.0.2" 65535)

    it "rejects empty or unusable hosts and node IDs" $ do
      currentTime <- getCurrentTime
      mapM_
        (\host ->
          parseClusterSlots
            (clusterSlots [slotRange 0 16383 (nodeRecord host 7000 "node-1") []])
            currentTime
            `shouldSatisfy` isLeft)
        ["", "?", "bad host", BS.pack [0x7f], BS.pack [0xff]]
      shouldFailWith
        "empty node ID"
        (clusterSlots [slotRange 0 16383 (nodeRecord "127.0.0.1" 7000 "") []])
        currentTime

    it "rejects invalid node record shapes" $ do
      currentTime <- getCurrentTime
      let invalidRecords =
            [ RespBulkString "not-an-array",
              RespArray [],
              RespArray [RespBulkString "127.0.0.1"],
              RespArray [RespInteger 1, RespInteger 7000, RespBulkString "node-1"],
              RespArray [RespBulkString "127.0.0.1", RespBulkString "7000", RespBulkString "node-1"],
              RespArray [RespBulkString "127.0.0.1", RespInteger 7000, RespInteger 1]
            ]
      mapM_
        (\record ->
          parseClusterSlots (clusterSlots [slotRange 0 16383 record []]) currentTime
            `shouldSatisfy` isLeft)
        invalidRecords

    it "rejects missing slot coverage" $ do
      currentTime <- getCurrentTime
      shouldFailWith "does not cover slot 0" (clusterSlots []) currentTime
      shouldFailWith
        "does not cover slot 101"
        (clusterSlots
          [ slotRange 0 100 validMaster [],
            slotRange 102 16383 (nodeRecord "127.0.0.2" 7001 "node-2") []
          ])
        currentTime

    it "rejects exact, contained, partial, and out-of-order overlaps" $ do
      currentTime <- getCurrentTime
      let node2Record = nodeRecord "127.0.0.2" 7001 "node-2"
          overlapCases :: [(String, Int, RespData)]
          overlapCases =
            [ ( "exact duplicate for the same node",
                0,
                clusterSlots
                  [ slotRange 0 16383 validMaster [],
                    slotRange 0 16383 validMaster []
                  ]
              ),
              ( "contained range with conflicting ownership",
                100,
                clusterSlots
                  [ slotRange 0 16383 validMaster [],
                    slotRange 100 200 node2Record []
                  ]
              ),
              ( "partial overlap for the same node",
                100,
                clusterSlots
                  [ slotRange 0 100 validMaster [],
                    slotRange 100 16383 validMaster []
                  ]
              ),
              ( "out-of-order partial overlap with conflicting ownership",
                100,
                clusterSlots
                  [ slotRange 100 16383 validMaster [],
                    slotRange 0 100 node2Record []
                  ]
              )
            ]
      mapM_
        (\(label, overlappingSlot, response) ->
          case parseClusterSlots response currentTime of
            Left err ->
              err `shouldContain`
                ("assigns slot " ++ show overlappingSlot ++ " more than once")
            Right _ ->
              expectationFailure $
                "Expected overlap validation failure for " ++ label)
        overlapCases

    it "rejects conflicting addresses and roles for a repeated node ID" $ do
      currentTime <- getCurrentTime
      let conflictingAddress = clusterSlots
            [ slotRange 0 100 validMaster [],
              slotRange 101 16383 (nodeRecord "127.0.0.2" 7001 "node-1") []
            ]
          conflictingRole = clusterSlots
            [ slotRange
                0
                100
                validMaster
                [nodeRecord "127.0.0.2" 7001 "node-2"],
              slotRange 101 16383 (nodeRecord "127.0.0.2" 7001 "node-2") []
            ]
      shouldFailWith "conflicting addresses" conflictingAddress currentTime
      shouldFailWith "both master and replica" conflictingRole currentTime

    it "is total across a deterministic matrix of malformed nested RESP values" $ do
      currentTime <- getCurrentTime
      mapM_
        (\(label, response) -> do
          result <- try $ evaluate $
            case parseClusterSlots response currentTime of
              Left err       -> length err
              Right topology -> forceTopology topology
          case (result :: Either SomeException Int) of
            Left err ->
              expectationFailure $
                "Synchronous exception for malformed case " ++ label
                  ++ ": " ++ show err
            Right _ -> return ()
          case parseClusterSlots response currentTime of
            Left err -> length err `shouldSatisfy` (> 0)
            Right _ ->
              expectationFailure $
                "Expected Left for malformed case " ++ label)
        malformedTopologyResponses

  describe "Node lookup" $ do
    it "returns Nothing for invalid slots or manually incomplete vectors" $ do
      currentTime <- getCurrentTime
      let emptyTopology = ClusterTopology V.empty V.empty Map.empty currentTime
          sentinelTopology =
            ClusterTopology
              (V.replicate 16384 "")
              (V.replicate 16384 (NodeAddress "" 0))
              Map.empty
              currentTime
      findNodeForSlot emptyTopology 0 `shouldBe` Nothing
      findNodeAddressForSlot emptyTopology 0 `shouldBe` Nothing
      findNodeForSlot sentinelTopology 0 `shouldBe` Nothing
      findNodeAddressForSlot sentinelTopology 0 `shouldBe` Nothing
      findNodeForSlot sentinelTopology 16384 `shouldBe` Nothing
      findNodeAddressForSlot sentinelTopology 16384 `shouldBe` Nothing

clusterSlots :: [RespData] -> RespData
clusterSlots = RespArray

slotRange :: Integer -> Integer -> RespData -> [RespData] -> RespData
slotRange start end master replicas =
  RespArray (RespInteger start : RespInteger end : master : replicas)

nodeRecord :: BS.ByteString -> Integer -> BS.ByteString -> RespData
nodeRecord host port nodeIdBS =
  RespArray
    [ RespBulkString host,
      RespInteger port,
      RespBulkString nodeIdBS
    ]

validMaster :: RespData
validMaster = nodeRecord "127.0.0.1" 7000 "node-1"

malformedTopologyResponses :: [(String, RespData)]
malformedTopologyResponses =
  labelCases "top-level value" malformedTopLevel
    ++ labelCases "slot-range entry" (map (clusterSlots . pure) malformedRangeEntries)
    ++ labelCases "range start" (map rangeWithStart malformedIntegerValues)
    ++ labelCases "range end" (map rangeWithEnd malformedIntegerValues)
    ++ labelCases "master node" (map rangeWithMaster malformedNodeValues)
    ++ labelCases "replica node" (map rangeWithReplica malformedNodeValues)
    ++ labelCases "node host" (map (rangeWithNodeField 0) malformedBulkStringValues)
    ++ labelCases "node port" (map (rangeWithNodeField 1) malformedIntegerValues)
    ++ labelCases "node ID" (map (rangeWithNodeField 2) malformedBulkStringValues)
  where
    malformedAtoms =
      [ RespSimpleString "simple",
        RespError "ERR malformed",
        RespInteger 7,
        RespBulkString "bulk",
        RespNullBulkString,
        RespSet (Set.fromList [RespInteger 1, RespNullBulkString]),
        RespMap (Map.fromList [(RespBulkString "key", RespArray [RespNullBulkString])])
      ]
    nestedArrays =
      [ RespArray [],
        RespArray [RespNullBulkString],
        RespArray [RespArray []],
        RespArray [RespArray [RespArray [RespNullBulkString]]]
      ]
    malformedTopLevel = malformedAtoms ++ nestedArrays
    malformedRangeEntries = malformedAtoms ++ nestedArrays
    malformedNodeValues = malformedAtoms ++ nestedArrays
    malformedIntegerValues =
      [ RespSimpleString "0",
        RespError "ERR integer",
        RespBulkString "0",
        RespNullBulkString,
        RespSet (Set.singleton (RespInteger 0)),
        RespMap (Map.singleton (RespBulkString "0") (RespInteger 0))
      ] ++ nestedArrays
    malformedBulkStringValues =
      [ RespSimpleString "text",
        RespError "ERR bulk",
        RespInteger 1,
        RespNullBulkString,
        RespSet (Set.singleton (RespBulkString "text")),
        RespMap (Map.singleton (RespBulkString "key") (RespBulkString "value"))
      ] ++ nestedArrays
    rangeWithStart value =
      clusterSlots [RespArray [value, RespInteger 16383, validMaster]]
    rangeWithEnd value =
      clusterSlots [RespArray [RespInteger 0, value, validMaster]]
    rangeWithMaster value =
      clusterSlots [slotRange 0 16383 value []]
    rangeWithReplica value =
      clusterSlots [slotRange 0 16383 validMaster [value]]
    rangeWithNodeField fieldIndex value =
      clusterSlots
        [ slotRange
            0
            16383
            (RespArray (replaceAt fieldIndex value validNodeFields))
            []
        ]
    validNodeFields =
      [ RespBulkString "127.0.0.1",
        RespInteger 7000,
        RespBulkString "node-1"
      ]

labelCases :: String -> [RespData] -> [(String, RespData)]
labelCases position =
  zipWith
    (\index response -> (position ++ " #" ++ show index, response))
    [0 :: Int ..]

replaceAt :: Int -> a -> [a] -> [a]
replaceAt index replacement values =
  take index values ++ [replacement] ++ drop (index + 1) values

forceTopology :: ClusterTopology -> Int
forceTopology topology =
  V.foldl' (\total nodeIdBS -> total + BS.length nodeIdBS) 0 (topologySlots topology)
    + V.foldl'
        (\total address -> total + length (nodeHost address) + nodePort address)
        0
        (topologyAddresses topology)
    + Map.foldl'
        (\total node ->
          total
            + BS.length (nodeId node)
            + length (nodeHost (nodeAddress node))
            + nodePort (nodeAddress node)
            + length (nodeSlotsServed node)
            + length (nodeReplicas node))
        0
        (topologyNodes topology)

shouldFailWith :: String -> RespData -> UTCTime -> Expectation
shouldFailWith expected response currentTime =
  case parseClusterSlots response currentTime of
    Left err -> err `shouldContain` expected
    Right _ -> expectationFailure $ "Expected topology validation failure containing: " ++ expected
