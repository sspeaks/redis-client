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

import           Control.Monad         (foldM)
import           Data.ByteString       (ByteString)
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BS8
import           Data.Either           (isRight)
import           Data.List             (find)
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
-- Respects hash tags: non-empty bytes inside the first brace candidate are hashed.
calculateSlot :: ByteString -> Word16
calculateSlot key =
  let !hashKey = extractHashTag key
  in crc16 hashKey
{-# INLINE calculateSlot #-}

-- | Extract the Redis Cluster hash tag from a key, if present.
-- The first opening brace and the first closing brace after it form the only
-- candidate. The enclosed bytes are used when non-empty; otherwise the full key
-- is returned.
-- Examples:
--   "{user}:profile" -> "user"
--   "prefix{user}:profile" -> "user"
--   "key" -> "key"
--   "{}" -> "{}"
--   "{user" -> "{user"
--   "foo{}{bar}" -> "foo{}{bar}"
extractHashTag :: ByteString -> ByteString
extractHashTag key =
  case BS.break (== 0x7b) key of
    (_, rest)
      | BS.null rest -> key
      | otherwise ->
          case BS.break (== 0x7d) (BS.tail rest) of
            (tag, closing)
              | not (BS.null tag) && not (BS.null closing) -> tag
              | otherwise -> key

-- | Parse and validate a complete @CLUSTER SLOTS@ response.
--
-- Successful topologies must cover every slot exactly once. Gaps and all
-- overlaps, including duplicate ranges for the same node, are rejected because
-- they represent incomplete or ambiguous routing snapshots. A node may own
-- multiple disjoint ranges when its address and role remain consistent.
-- Node records require a non-empty printable ASCII endpoint other than @?@, a
-- port in @1-65535@, and a non-empty node ID. Additional node metadata fields
-- are accepted and ignored.
parseClusterSlots :: RespData -> UTCTime -> Either String ClusterTopology
parseClusterSlots (RespArray slots) currentTime = do
  ranges <- mapM (uncurry parseSlotRange) (zip [0 :: Int ..] slots)
  slotAssignments <- foldM assignSlots emptySlotAssignments ranges
  slotMap <- case sequenceA slotAssignments of
    Left missingSlot ->
      Left $ "CLUSTER SLOTS response does not cover slot " ++ show missingSlot
    Right assignments -> Right assignments
  nodeMap <- foldM buildNodeMap Map.empty ranges
  addressMap <- buildAddressVector slotMap nodeMap
  return $ ClusterTopology slotMap addressMap nodeMap currentTime
  where
    parseSlotRange
      :: Int
      -> RespData
      -> Either String (SlotRange, (ByteString, NodeAddress), [(ByteString, NodeAddress)])
    parseSlotRange rangeIndex (RespArray (RespInteger start : RespInteger end : masterInfo : replicaInfos)) = do
      (startSlot, endSlot) <- validateSlotRange rangeIndex start end
      master <- parseNodeInfo ("master in slot range " ++ show start ++ "-" ++ show end) masterInfo
      replicas <- mapM
        (uncurry $ parseIndexedReplica start end)
        (zip [0 :: Int ..] replicaInfos)
      let replicaIds = unique (map fst replicas)
      let range = SlotRange
            { slotStart = startSlot,
              slotEnd = endSlot,
              slotMaster = fst master,
              slotReplicas = replicaIds
            }
      return (range, master, replicas)
    parseSlotRange rangeIndex other =
      Left $
        "CLUSTER SLOTS entry " ++ show rangeIndex
          ++ " must be an array containing start, end, and a master node: "
          ++ show other

    parseIndexedReplica
      :: Integer
      -> Integer
      -> Int
      -> RespData
      -> Either String (ByteString, NodeAddress)
    parseIndexedReplica start end replicaIndex =
      parseNodeInfo $
        "replica " ++ show replicaIndex
          ++ " in slot range " ++ show start ++ "-" ++ show end

    validateSlotRange :: Int -> Integer -> Integer -> Either String (Word16, Word16)
    validateSlotRange rangeIndex start end
      | start < 0 =
          Left $ rangeError rangeIndex $ "start slot is negative: " ++ show start
      | end < 0 =
          Left $ rangeError rangeIndex $ "end slot is negative: " ++ show end
      | start > end =
          Left $
            rangeError rangeIndex $
              "start slot " ++ show start ++ " exceeds end slot " ++ show end
      | end >= fromIntegral slotCount =
          Left $
            rangeError rangeIndex $
              "end slot " ++ show end ++ " is outside 0-" ++ show (slotCount - 1)
      | otherwise = Right (fromInteger start, fromInteger end)

    rangeError :: Int -> String -> String
    rangeError rangeIndex message =
      "CLUSTER SLOTS entry " ++ show rangeIndex ++ " has invalid range: " ++ message

    parseNodeInfo :: String -> RespData -> Either String (ByteString, NodeAddress)
    parseNodeInfo context (RespArray (RespBulkString host : RespInteger port : RespBulkString nodeIdBS : _))
      | BS.null host =
          Left $ "CLUSTER SLOTS " ++ context ++ " has an empty host"
      | host == "?" =
          Left $ "CLUSTER SLOTS " ++ context ++ " has unusable host \"?\""
      | BS.any isInvalidHostByte host =
          Left $ "CLUSTER SLOTS " ++ context ++ " has a non-printable host"
      | port < 1 || port > 65535 =
          Left $
            "CLUSTER SLOTS " ++ context ++ " has port outside 1-65535: "
              ++ show port
      | BS.null nodeIdBS =
          Left $ "CLUSTER SLOTS " ++ context ++ " has an empty node ID"
      | otherwise =
          Right (nodeIdBS, NodeAddress (BS8.unpack host) (fromInteger port))
    parseNodeInfo context other =
      Left $
        "CLUSTER SLOTS " ++ context
          ++ " must be an array containing bulk-string host, integer port, and bulk-string node ID: "
          ++ show other

    isInvalidHostByte byte = byte < 0x21 || byte > 0x7e

    emptySlotAssignments :: Vector (Either Int ByteString)
    emptySlotAssignments = V.generate slotCount Left

    assignSlots
      :: Vector (Either Int ByteString)
      -> (SlotRange, (ByteString, NodeAddress), [(ByteString, NodeAddress)])
      -> Either String (Vector (Either Int ByteString))
    assignSlots assignments (range, _, _) =
      case find isAssigned rangeSlots of
        Just overlappingSlot ->
          Left $
            "CLUSTER SLOTS response assigns slot " ++ show overlappingSlot
              ++ " more than once"
        Nothing ->
          Right $
            assignments V.//
              [ (fromIntegral slot, Right (slotMaster range))
              | slot <- rangeSlots
              ]
      where
        rangeSlots = [slotStart range .. slotEnd range]
        isAssigned slot =
          maybe False isRight (assignments V.!? fromIntegral slot)

    buildNodeMap
      :: Map ByteString ClusterNode
      -> (SlotRange, (ByteString, NodeAddress), [(ByteString, NodeAddress)])
      -> Either String (Map ByteString ClusterNode)
    buildNodeMap nodeMap (range, master, replicas) = do
      withMaster <- insertNode range (map fst replicas) Master master nodeMap
      foldM (\nodes replica -> insertNode range [] Replica replica nodes) withMaster replicas

    insertNode
      :: SlotRange
      -> [ByteString]
      -> NodeRole
      -> (ByteString, NodeAddress)
      -> Map ByteString ClusterNode
      -> Either String (Map ByteString ClusterNode)
    insertNode range replicaIds role (nodeIdBS, address) nodeMap =
      case Map.lookup nodeIdBS nodeMap of
        Nothing ->
          Right $
            Map.insert
              nodeIdBS
              (ClusterNode nodeIdBS address role [range] (unique replicaIds))
              nodeMap
        Just node
          | nodeAddress node /= address ->
              Left $
                "CLUSTER SLOTS node " ++ show nodeIdBS
                  ++ " has conflicting addresses "
                  ++ show (nodeAddress node) ++ " and " ++ show address
          | nodeRole node /= role ->
              Left $
                "CLUSTER SLOTS node " ++ show nodeIdBS
                  ++ " appears as both master and replica"
          | otherwise ->
              Right $
                Map.insert
                  nodeIdBS
                  node
                    { nodeSlotsServed = nodeSlotsServed node ++ [range],
                      nodeReplicas = unique (nodeReplicas node ++ replicaIds)
                    }
                  nodeMap

    unique :: Eq a => [a] -> [a]
    unique = foldr (\item items -> if item `elem` items then items else item : items) []
parseClusterSlots other _ = Left $ "Expected array of slot ranges, got: " ++ show other

-- | Build a slot-to-NodeAddress vector from the slot-to-nodeId vector and node map.
-- Used for O(1) hot path lookups that skip the Map entirely.
buildAddressVector :: Vector ByteString -> Map ByteString ClusterNode -> Either String (Vector NodeAddress)
buildAddressVector slotVec nodeMap =
  traverse
    (\nodeIdBS ->
      case Map.lookup nodeIdBS nodeMap of
        Just node -> Right (nodeAddress node)
        Nothing ->
          Left $
            "CLUSTER SLOTS internal validation error: missing node "
              ++ show nodeIdBS)
    slotVec

slotCount :: Int
slotCount = 16384

-- | Look up the master node ID responsible for a given slot.
-- Returns 'Nothing' if the slot is out of range or the topology was manually
-- constructed with missing ownership.
findNodeForSlot :: ClusterTopology -> Word16 -> Maybe ByteString
findNodeForSlot topology slot
  | slot >= fromIntegral slotCount = Nothing
  | otherwise = do
      nodeIdBS <- topologySlots topology V.!? fromIntegral slot
      if BS.null nodeIdBS then Nothing else Just nodeIdBS

-- | Look up the 'NodeAddress' responsible for a given slot directly (O(1), no Map lookup).
-- Returns 'Nothing' if the slot is out of range or the topology was manually
-- constructed with an unusable placeholder address.
findNodeAddressForSlot :: ClusterTopology -> Word16 -> Maybe NodeAddress
findNodeAddressForSlot topology slot
  | slot >= fromIntegral slotCount = Nothing
  | otherwise = do
      address <- topologyAddresses topology V.!? fromIntegral slot
      if null (nodeHost address) || nodePort address < 1 || nodePort address > 65535
        then Nothing
        else Just address
{-# INLINE findNodeAddressForSlot #-}
