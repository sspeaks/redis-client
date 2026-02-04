{-# LANGUAGE OverloadedStrings #-}

module Cluster
  ( ClusterNode (..),
    SlotRange (..),
    ClusterTopology (..),
    NodeRole (..),
    NodeAddress (..),
    calculateSlot,
    extractHashTag,
    parseClusterSlots,
    findNodeForSlot,
  )
where

import           Crc16                      (crc16)
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy.Char8 as LBSC
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Time                  (UTCTime)
import           Data.Vector                (Vector)
import qualified Data.Vector                as V
import           Data.Word                  (Word16)
import           Resp                       (RespData (..))

-- | Node role in the cluster
data NodeRole = Master | Replica
  deriving (Show, Eq)

-- | Node address for connection
data NodeAddress = NodeAddress
  { nodeHost :: String,
    nodePort :: Int
  }
  deriving (Show, Eq, Ord)

-- | Represents a cluster node with its metadata
data ClusterNode = ClusterNode
  { nodeId          :: Text,
    nodeAddress     :: NodeAddress,
    nodeRole        :: NodeRole,
    nodeSlotsServed :: [SlotRange],
    nodeReplicas    :: [Text] -- Node IDs of replicas
  }
  deriving (Show, Eq)

-- | Represents a range of slots and the nodes serving them
data SlotRange = SlotRange
  { slotStart    :: Word16, -- 0-16383
    slotEnd      :: Word16,
    slotMaster   :: Text, -- Node ID reference
    slotReplicas :: [Text] -- Node ID references
  }
  deriving (Show, Eq)

-- | Complete cluster topology
data ClusterTopology = ClusterTopology
  { topologySlots      :: Vector Text, -- 16384 slots, each mapped to node ID
    topologyNodes      :: Map Text ClusterNode, -- Node ID -> full node details
    topologyUpdateTime :: UTCTime
  }
  deriving (Show)

-- | Calculate the hash slot for a given key
-- Uses the existing CRC16 implementation which already computes mod 16384
calculateSlot :: ByteString -> IO Word16
calculateSlot key = do
  let hashKey = extractHashTag key
  crc16 hashKey

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

-- | Parse CLUSTER SLOTS response into ClusterTopology
parseClusterSlots :: RespData -> UTCTime -> Either String ClusterTopology
parseClusterSlots (RespArray slots) currentTime = do
  ranges <- mapM parseSlotRange slots
  let (slotMap, nodeMap) = buildTopology ranges
  return $ ClusterTopology slotMap nodeMap currentTime
  where
    parseSlotRange :: RespData -> Either String (SlotRange, [(Text, NodeAddress)])
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

    parseNodeInfo :: RespData -> Either String (Text, NodeAddress)
    parseNodeInfo (RespArray (RespBulkString host : RespInteger port : RespBulkString nodeId : _)) =
      Right (T.pack $ LBSC.unpack nodeId, NodeAddress (LBSC.unpack host) (fromIntegral port))
    parseNodeInfo other = Left $ "Invalid node info format: " ++ show other

    buildTopology :: [(SlotRange, [(Text, NodeAddress)])] -> (Vector Text, Map Text ClusterNode)
    buildTopology rangesWithNodes =
      let slotVector = V.replicate 16384 ""
          slotMap = foldl (\v (range, _) -> assignSlots v range) slotVector rangesWithNodes
          nodeMap = foldl buildNodeMap Map.empty rangesWithNodes
       in (slotMap, nodeMap)

    assignSlots :: Vector Text -> SlotRange -> Vector Text
    assignSlots vec range =
      foldl
        (\v slot -> v V.// [(fromIntegral slot, slotMaster range)])
        vec
        [slotStart range .. slotEnd range]

    buildNodeMap :: Map Text ClusterNode -> (SlotRange, [(Text, NodeAddress)]) -> Map Text ClusterNode
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
        insertNode :: Map Text ClusterNode -> (Text, NodeAddress) -> NodeRole -> Map Text ClusterNode
        insertNode nm (nodeId, addr) role =
          if Map.member nodeId nm
            then nm -- Node already exists, don't overwrite
            else Map.insert nodeId (ClusterNode nodeId addr role [range] []) nm
parseClusterSlots other _ = Left $ "Expected array of slot ranges, got: " ++ show other

-- | Find the node responsible for a given slot
findNodeForSlot :: ClusterTopology -> Word16 -> Maybe Text
findNodeForSlot topology slot
  | slot < 16384 = Just $ topologySlots topology V.! fromIntegral slot
  | otherwise = Nothing
