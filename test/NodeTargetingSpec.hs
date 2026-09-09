{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.ByteString          as BS
import           Data.List                (isInfixOf)
import qualified Data.Map.Strict          as Map
import           Data.Time.Clock.POSIX    (posixSecondsToUTCTime)
import qualified Data.Vector              as V
import           Data.Word                (Word16)
import           Database.Redis.Cluster
import           LibraryE2E.NodeLifecycle (NodeTarget (..))
import           LibraryE2E.NodeTargeting
import           Test.Hspec

main :: IO ()
main = hspec $ describe "LibraryE2E node targeting" $ do
  it "maps fixture node numbers to the configured container address" $ do
    dockerNodeTarget 3 `shouldBe` Right target
    dockerNodeTarget 0 `shouldBe`
      Left "Redis cluster node must be between 1 and 5, got 0"

  it "maps a Docker target to its advertised master and owned slots" $ do
    let scenario = resolveNodeOutageScenario 1000 target fixtureTopology
    case scenario of
      Left err -> expectationFailure err
      Right resolved -> do
        nodeAddress (stoppedClusterNode resolved)
          `shouldBe` NodeAddress "redis3.local" 6381
        calculateSlot (stoppedNodeKey resolved)
          `shouldSatisfy` inRange stoppedRange
        nodeAddress (healthyClusterNode resolved)
          `shouldBe` NodeAddress "redis1.local" 6379
        calculateSlot (healthyNodeKey resolved)
          `shouldSatisfy` inRange healthyRange

  it "generates binary keys whose calculated slot is inside the range" $ do
    let binaryPrefix = BS.pack [0x00, 0xff, 0x80, 0x01]
    case findKeyForSlotRanges 1000 binaryPrefix [stoppedRange] of
      Left err -> expectationFailure err
      Right key -> do
        binaryPrefix `BS.isPrefixOf` key `shouldBe` True
        calculateSlot key `shouldSatisfy` inRange stoppedRange

  it "returns a bounded failure when candidates cannot reach the range" $ do
    let fixedSlot = calculateSlot "{fixed}"
        unreachable
          | fixedSlot == 0 = SlotRange 1 1 "other" []
          | otherwise = SlotRange 0 0 "other" []
    findKeyForSlotRanges 3 "{fixed}" [unreachable]
      `shouldBe` Left
        "Could not find a key in the requested slot ranges after 3 attempts"

  it "rejects ambiguous advertised node mappings" $ do
    let duplicate = stoppedNode
          { nodeId = "duplicate"
          , nodeSlotsServed = [SlotRange 10001 10001 "duplicate" []]
          }
        topology = fixtureTopology
          { topologyNodes = Map.insert "duplicate" duplicate $
              topologyNodes fixtureTopology
          }
    resolveNodeOutageScenario 1000 target topology
      `shouldBe` Left
        "Multiple cluster nodes advertise Docker target redis3.local:6381"

  it "rejects a target with replicas because failure is not deterministic" $ do
    let replicated = stoppedNode
          { nodeReplicas = ["replica"]
          }
        topology = fixtureTopology
          { topologyNodes = Map.insert "stopped" replicated $
              topologyNodes fixtureTopology
          }
    resolveNodeOutageScenario 1000 target topology `shouldSatisfy` \case
      Left err -> "has replicas" `isInfixOf` err
      Right _  -> False

target :: NodeTarget
target = NodeTarget
  { nodeNumber = 3
  , nodeContainer = "redis-cluster-node3"
  , targetHost = "redis3.local"
  , targetPort = 6381
  }

healthyRange :: SlotRange
healthyRange = SlotRange 0 5000 "healthy" []

stoppedRange :: SlotRange
stoppedRange = SlotRange 5001 10000 "stopped" []

healthyNode :: ClusterNode
healthyNode = ClusterNode
  { nodeId = "healthy"
  , nodeAddress = NodeAddress "redis1.local" 6379
  , nodeRole = Master
  , nodeSlotsServed = [healthyRange]
  , nodeReplicas = []
  }

stoppedNode :: ClusterNode
stoppedNode = ClusterNode
  { nodeId = "stopped"
  , nodeAddress = NodeAddress "redis3.local" 6381
  , nodeRole = Master
  , nodeSlotsServed = [stoppedRange]
  , nodeReplicas = []
  }

otherNode :: ClusterNode
otherNode = ClusterNode
  { nodeId = "other"
  , nodeAddress = NodeAddress "redis5.local" 6383
  , nodeRole = Master
  , nodeSlotsServed = [SlotRange 10001 16383 "other" []]
  , nodeReplicas = []
  }

fixtureTopology :: ClusterTopology
fixtureTopology = ClusterTopology
  { topologySlots = V.generate 16384 slotOwner
  , topologyAddresses = V.generate 16384 slotAddress
  , topologyNodes = Map.fromList
      [ ("stopped", stoppedNode)
      , ("other", otherNode)
      , ("healthy", healthyNode)
      ]
  , topologyUpdateTime = posixSecondsToUTCTime 0
  }
  where
    slotOwner slot
      | slot <= 5000 = "healthy"
      | slot <= 10000 = "stopped"
      | otherwise = "other"
    slotAddress slot
      | slot <= 5000 = nodeAddress healthyNode
      | slot <= 10000 = nodeAddress stoppedNode
      | otherwise = nodeAddress otherNode

inRange :: SlotRange -> Word16 -> Bool
inRange range slot =
  slot >= slotStart range && slot <= slotEnd range
