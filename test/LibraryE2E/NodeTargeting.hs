{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.NodeTargeting
  ( NodeOutageScenario (..)
  , dockerNodeTarget
  , findKeyForSlotRanges
  , resolveNodeOutageScenario
  ) where

import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as BS
import           Data.List                (sortOn)
import qualified Data.Map.Strict          as Map
import qualified Data.Vector              as V
import           Data.Word                (Word16, Word64)
import           Database.Redis.Cluster
import           LibraryE2E.NodeLifecycle (NodeTarget (..))

data NodeOutageScenario = NodeOutageScenario
  { stoppedClusterNode :: ClusterNode
  , stoppedNodeKey     :: ByteString
  , healthyClusterNode :: ClusterNode
  , healthyNodeKey     :: ByteString
  } deriving (Eq, Show)

dockerNodeTarget :: Int -> Either String NodeTarget
dockerNodeTarget node
  | node >= 1 && node <= 5 =
      Right NodeTarget
        { nodeNumber = node
        , nodeContainer = "redis-cluster-node" ++ show node
        , targetHost = "redis" ++ show node ++ ".local"
        , targetPort = 6378 + node
        }
  | otherwise =
      Left $ "Redis cluster node must be between 1 and 5, got " ++ show node

resolveNodeOutageScenario
  :: Int
  -> NodeTarget
  -> ClusterTopology
  -> Either String NodeOutageScenario
resolveNodeOutageScenario searchLimit target topology = do
  stopped <- resolveTargetNode target topology
  healthy <- resolveHealthyNode stopped topology
  stoppedKey <- findKeyForNode
    searchLimit
    "library-e2e-stopped-"
    topology
    stopped
  healthyKey <- findKeyForNode
    searchLimit
    "library-e2e-healthy-"
    topology
    healthy
  return NodeOutageScenario
    { stoppedClusterNode = stopped
    , stoppedNodeKey = stoppedKey
    , healthyClusterNode = healthy
    , healthyNodeKey = healthyKey
    }

findKeyForSlotRanges
  :: Int
  -> ByteString
  -> [SlotRange]
  -> Either String ByteString
findKeyForSlotRanges searchLimit prefix ranges
  | searchLimit <= 0 =
      Left "Key search limit must be positive"
  | null ranges =
      Left "Cannot generate a key for an empty slot range list"
  | otherwise =
      search 0
  where
    search index
      | index >= searchLimit =
          Left $ "Could not find a key in the requested slot ranges after "
            ++ show searchLimit ++ " attempts"
      | slotInRanges (calculateSlot candidate) ranges =
          Right candidate
      | otherwise =
          search $ index + 1
      where
        candidate = prefix <> encodeCounter (fromIntegral index)

resolveTargetNode
  :: NodeTarget
  -> ClusterTopology
  -> Either String ClusterNode
resolveTargetNode target topology =
  case filter matchesTarget $ Map.elems $ topologyNodes topology of
    [node] -> validateRoutableMaster topology node
    [] ->
      Left $ "No cluster node advertises Docker target "
        ++ renderTargetAddress target
    _ ->
      Left $ "Multiple cluster nodes advertise Docker target "
        ++ renderTargetAddress target
  where
    matchesTarget node =
      nodeAddress node == NodeAddress (targetHost target) (targetPort target)

resolveHealthyNode
  :: ClusterNode
  -> ClusterTopology
  -> Either String ClusterNode
resolveHealthyNode stopped topology =
  case validHealthyNodes of
    node : _ -> Right node
    [] ->
      Left "No healthy master with owned slots exists outside the stopped node"
  where
    validHealthyNodes =
      sortOn nodeAddress
        [ node
        | node <- Map.elems $ topologyNodes topology
        , nodeId node /= nodeId stopped
        , nodeRole node == Master
        , not $ null $ nodeSlotsServed node
        , rangesMatchTopology topology node
        ]

validateRoutableMaster
  :: ClusterTopology
  -> ClusterNode
  -> Either String ClusterNode
validateRoutableMaster topology node
  | nodeRole node /= Master =
      Left $ "Docker target is not a master: " ++ show (nodeAddress node)
  | not $ null $ nodeReplicas node =
      Left $ "Docker target has replicas, so an outage may fail over: "
        ++ show (nodeAddress node)
  | null $ nodeSlotsServed node =
      Left $ "Docker target owns no slots: " ++ show (nodeAddress node)
  | not $ rangesMatchTopology topology node =
      Left $ "Docker target slot ranges disagree with the routing vector: "
        ++ show (nodeAddress node)
  | otherwise =
      Right node

findKeyForNode
  :: Int
  -> ByteString
  -> ClusterTopology
  -> ClusterNode
  -> Either String ByteString
findKeyForNode searchLimit prefix topology node = do
  key <- findKeyForSlotRanges searchLimit prefix $ nodeSlotsServed node
  let slot = calculateSlot key
  case findNodeAddressForSlot topology slot of
    Just address
      | address == nodeAddress node ->
          Right key
    actual ->
      Left $ "Generated slot " ++ show slot
        ++ " routed to " ++ show actual
        ++ " instead of " ++ show (nodeAddress node)

rangesMatchTopology :: ClusterTopology -> ClusterNode -> Bool
rangesMatchTopology topology node =
  all slotMatches $ concatMap rangeSlots $ nodeSlotsServed node
  where
    slotMatches slot =
      topologySlots topology V.!? fromIntegral slot == Just (nodeId node)

slotInRanges :: Word16 -> [SlotRange] -> Bool
slotInRanges slot =
  any $ \range -> slot >= slotStart range && slot <= slotEnd range

rangeSlots :: SlotRange -> [Word16]
rangeSlots range = [slotStart range .. slotEnd range]

encodeCounter :: Word64 -> ByteString
encodeCounter value =
  BS.pack
    [ fromIntegral $ value `div` 0x100000000000000
    , fromIntegral $ value `div` 0x1000000000000
    , fromIntegral $ value `div` 0x10000000000
    , fromIntegral $ value `div` 0x100000000
    , fromIntegral $ value `div` 0x1000000
    , fromIntegral $ value `div` 0x10000
    , fromIntegral $ value `div` 0x100
    , fromIntegral value
    ]

renderTargetAddress :: NodeTarget -> String
renderTargetAddress target =
  targetHost target ++ ":" ++ show (targetPort target)
