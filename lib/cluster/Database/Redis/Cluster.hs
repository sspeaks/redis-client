{-# LANGUAGE OverloadedStrings #-}

-- | Redis cluster topology model and slot routing.
--
-- Provides types for representing cluster nodes, slot ranges, and the full topology,
-- plus functions to compute hash slots, parse @CLUSTER SLOTS@ responses, and look up
-- which node owns a given slot.
--
-- @since 0.1.0.0
module Database.Redis.Cluster
  ( ClusterNode (..),
    SlotRange (..),
    ClusterTopology (..),
    NodeRole (..),
    NodeAddress (..),
    calculateSlot,
    extractHashTag,
    parseClusterSlots,
    findNodeForSlot,
    findNodeAddressForSlot,
  )
where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BS8
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Time             (UTCTime)
import           Data.Vector           (Vector)
import qualified Data.Vector           as V
import           Data.Word             (Word16)
import           Database.Redis.Crc16  (crc16)
import           Database.Redis.Resp   (RespData (..))

-- | Node role in the cluster
data NodeRole = Master | Replica
  deriving (Show, Eq)

-- | Network address for connecting to a cluster node.
data NodeAddress = NodeAddress
  { nodeHost :: String,
    nodePort :: Int
  }
  deriving (Show, Eq, Ord)

-- | A cluster node with its identity, address, role, and slot assignments.
data ClusterNode = ClusterNode
  { nodeId          :: ByteString,
    nodeAddress     :: NodeAddress,
    nodeRole        :: NodeRole,
    nodeSlotsServed :: [SlotRange],
    nodeReplicas    :: [ByteString] -- Node IDs of replicas
  }
  deriving (Show, Eq)

-- | A contiguous range of hash slots and the nodes responsible for them.
data SlotRange = SlotRange
  { slotStart    :: Word16, -- 0-16383
    slotEnd      :: Word16,
    slotMaster   :: ByteString, -- Node ID reference
    slotReplicas :: [ByteString] -- Node ID references
  }
  deriving (Show, Eq)

-- | Full snapshot of the cluster topology: a fast O(1) slot-to-node vector,
-- a map of all known nodes, and the time the snapshot was taken.
data ClusterTopology = ClusterTopology
  { topologySlots      :: Vector ByteString,     -- 16384 slots, each mapped to node ID
    topologyAddresses  :: Vector NodeAddress,     -- 16384 slots, each mapped directly to NodeAddress (hot path)
    topologyNodes      :: Map ByteString ClusterNode, -- Node ID -> full node details
    topologyUpdateTime :: UTCTime
  }
  deriving (Show)

-- | Calculate the hash slot (0–16383) for a Redis key.
-- Respects hash tags: if the key starts with @{tag}@, only @tag@ is hashed.
calculateSlot :: ByteString -> Word16
calculateSlot key =
  let !hashKey = extractHashTag key
  in crc16 hashKey
{-# INLINE calculateSlot #-}

-- | Extract hash tag from a key if present
-- Pattern: {tag} - returns the content within the first valid {} pair
-- Examples:
--   "{user}:profile" -> "user"
--   "key" -> "key"
--   "{}" -> "{}"
--   "{user" -> "{user"
--   "key{tag}" -> "key{tag}" (no tag at end)
extractHashTag :: ByteString -> ByteString
extractHashTag key =
  case BS.breakSubstring "{" key of
    (before, rest)
      | not (BS.null rest) && not (BS.null before) ->
          -- Found { but there's content before it - no valid tag
          key
      | not (BS.null rest) ->
          -- Found { at start, check for closing }
          case BS.breakSubstring "}" (BS.tail rest) of
            (tag, after)
              | not (BS.null after) && not (BS.null tag) -> tag
              | otherwise -> key
      | otherwise -> key

-- | Parse the RESP response from @CLUSTER SLOTS@ into a 'ClusterTopology'.
-- Returns 'Left' with an error message if the response format is unexpected.
parseClusterSlots :: RespData -> UTCTime -> Either String ClusterTopology
parseClusterSlots (RespArray slots) currentTime = do
  ranges <- mapM parseSlotRange slots
  let (slotMap, nodeMap) = buildTopology ranges
      addrMap = buildAddressVector slotMap nodeMap
  return $ ClusterTopology slotMap addrMap nodeMap currentTime
  where
    parseSlotRange :: RespData -> Either String (SlotRange, [(ByteString, NodeAddress)])
    parseSlotRange (RespArray (RespInteger start : RespInteger end : masterInfo : replicaInfos)) = do
      master <- parseNodeInfo masterInfo
      replicas <- mapM parseNodeInfo replicaInfos
      let range = SlotRange
            { slotStart = fromIntegral start,
              slotEnd = fromIntegral end,
              slotMaster = fst master,
              slotReplicas = map fst replicas
            }
      return (range, master : replicas)
    parseSlotRange other = Left $ "Invalid slot range format: " ++ show other

    parseNodeInfo :: RespData -> Either String (ByteString, NodeAddress)
    parseNodeInfo (RespArray (RespBulkString host : RespInteger port : RespBulkString nodeIdBS : _)) =
      Right (nodeIdBS, NodeAddress (BS8.unpack host) (fromIntegral port))
    parseNodeInfo other = Left $ "Invalid node info format: " ++ show other

    buildTopology :: [(SlotRange, [(ByteString, NodeAddress)])] -> (Vector ByteString, Map ByteString ClusterNode)
    buildTopology rangesWithNodes =
      let slotVector = V.replicate 16384 ""
          slotMap = foldl (\v (range, _) -> assignSlots v range) slotVector rangesWithNodes
          nodeMap = foldl buildNodeMap Map.empty rangesWithNodes
       in (slotMap, nodeMap)

    assignSlots :: Vector ByteString -> SlotRange -> Vector ByteString
    assignSlots vec range =
      foldl
        (\v slot -> v V.// [(fromIntegral slot, slotMaster range)])
        vec
        [slotStart range .. slotEnd range]

    buildNodeMap :: Map ByteString ClusterNode -> (SlotRange, [(ByteString, NodeAddress)]) -> Map ByteString ClusterNode
    buildNodeMap nodeMap (range, nodeInfos) =
      case nodeInfos of
        [] -> nodeMap  -- No nodes in this range (shouldn't happen)
        (masterId, masterAddr) : replicaInfos ->
          -- Insert master node
          let nodeMapWithMaster = insertNode nodeMap (masterId, masterAddr) Master
              -- Insert replica nodes
              nodeMapWithReplicas = foldl (\nm (replicaId, replicaAddr) ->
                                            insertNode nm (replicaId, replicaAddr) Replica)
                                          nodeMapWithMaster replicaInfos
          in nodeMapWithReplicas
      where
        insertNode :: Map ByteString ClusterNode -> (ByteString, NodeAddress) -> NodeRole -> Map ByteString ClusterNode
        insertNode nm (nodeId, addr) role =
          if Map.member nodeId nm
            then nm -- Node already exists, don't overwrite
            else Map.insert nodeId (ClusterNode nodeId addr role [range] []) nm
parseClusterSlots other _ = Left $ "Expected array of slot ranges, got: " ++ show other

-- | Build a slot-to-NodeAddress vector from the slot-to-nodeId vector and node map.
-- Used for O(1) hot path lookups that skip the Map entirely.
buildAddressVector :: Vector ByteString -> Map ByteString ClusterNode -> Vector NodeAddress
buildAddressVector slotVec nodeMap =
  V.map (\nid -> case Map.lookup nid nodeMap of
    Just node -> nodeAddress node
    Nothing   -> NodeAddress "" 0  -- placeholder for unassigned slots
  ) slotVec

-- | Look up the master node ID responsible for a given slot.
-- Returns 'Nothing' if the slot is out of range (≥ 16384).
findNodeForSlot :: ClusterTopology -> Word16 -> Maybe ByteString
findNodeForSlot topology slot
  | slot < 16384 = Just $ topologySlots topology V.! fromIntegral slot
  | otherwise = Nothing

-- | Look up the 'NodeAddress' responsible for a given slot directly (O(1), no Map lookup).
-- Returns 'Nothing' if the slot is out of range (≥ 16384).
findNodeAddressForSlot :: ClusterTopology -> Word16 -> Maybe NodeAddress
findNodeAddressForSlot topology slot
  | slot < 16384 = Just $! topologyAddresses topology V.! fromIntegral slot
  | otherwise = Nothing
{-# INLINE findNodeAddressForSlot #-}
