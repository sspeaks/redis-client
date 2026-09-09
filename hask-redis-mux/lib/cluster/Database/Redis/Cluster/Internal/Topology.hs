{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Internal.Topology
  ( commitRefreshedTopology
  , mergeRefreshedTopology
  , patchMovedSlot
  , provisionalMovedPatches
  ) where

import           Control.Concurrent.STM (STM, TVar, readTVar, writeTVar)
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import           Data.List              (foldl')
import qualified Data.Map.Strict        as Map
import qualified Data.Vector            as V
import           Data.Word              (Word16)
import           Database.Redis.Cluster (ClusterNode (..), ClusterTopology (..),
                                         NodeAddress (..), NodeRole (..),
                                         SlotRange (..), findNodeAddressForSlot)

-- | Commit a fresh snapshot while retaining provisional MOVED routes learned
-- after that snapshot was requested.  Reading, merging, and writing are one
-- STM transaction so a concurrent patch cannot be lost between those steps.
commitRefreshedTopology
  :: TVar ClusterTopology
  -> [(Word16, NodeAddress)]
  -> ClusterTopology
  -> STM ()
commitRefreshedTopology topologyVar explicitPatches refreshed = do
  current <- readTVar topologyVar
  let merged = mergeRefreshedTopology
        refreshed (explicitPatches ++ provisionalMovedPatches current)
  writeTVar topologyVar merged

mergeRefreshedTopology
  :: ClusterTopology
  -> [(Word16, NodeAddress)]
  -> ClusterTopology
mergeRefreshedTopology refreshed =
  foldl'
    (\topology (slot, address) ->
      if findNodeAddressForSlot topology slot == Just address
        then topology
        else patchTopologySlot slot address topology)
    refreshed

patchMovedSlot :: TVar ClusterTopology -> Word16 -> NodeAddress -> STM ()
patchMovedSlot topologyVar slot address = do
  topology <- readTVar topologyVar
  writeTVar topologyVar (patchTopologySlot slot address topology)

provisionalMovedPatches :: ClusterTopology -> [(Word16, NodeAddress)]
provisionalMovedPatches topology =
  [ (fromIntegral index, topologyAddresses topology V.! index)
  | index <- [0 .. upperBound]
  , movedNodePrefix `BS.isPrefixOf` (topologySlots topology V.! index)
  ]
  where
    upperBound = min
      (V.length $ topologySlots topology)
      (V.length $ topologyAddresses topology)
      - 1

patchTopologySlot :: Word16 -> NodeAddress -> ClusterTopology -> ClusterTopology
patchTopologySlot slot _ topology
  | fromIntegral slot >= V.length (topologySlots topology)
      || fromIntegral slot >= V.length (topologyAddresses topology) =
      topology
patchTopologySlot slot address topology =
  topology
    { topologySlots =
        topologySlots topology V.// [(slotIndex, targetNodeId)]
    , topologyAddresses =
        topologyAddresses topology V.// [(slotIndex, address)]
    , topologyNodes =
        Map.insert targetNodeId targetNode nodesWithoutSlot
    }
  where
    slotIndex = fromIntegral slot
    targetNodeId = movedNodeId address
    nodesWithoutSlot =
      Map.map (removeSlotFromNode slot) $ topologyNodes topology
    existingTarget =
      Map.lookup targetNodeId nodesWithoutSlot
    targetNode = case existingTarget of
      Just node ->
        node
          { nodeAddress = address
          , nodeRole = Master
          , nodeSlotsServed = movedRange : nodeSlotsServed node
          }
      Nothing -> ClusterNode targetNodeId address Master [movedRange] []
    movedRange = SlotRange slot slot targetNodeId []

movedNodePrefix :: BS.ByteString
movedNodePrefix = "__redis_client_moved__:"

movedNodeId :: NodeAddress -> BS.ByteString
movedNodeId address =
  movedNodePrefix <> BS8.pack (nodeHost address) <> ":" <> BS8.pack (show $ nodePort address)

removeSlotFromNode :: Word16 -> ClusterNode -> ClusterNode
removeSlotFromNode slot node =
  node
    { nodeSlotsServed =
        concatMap removeSlotFromRange $ nodeSlotsServed node
    }
  where
    removeSlotFromRange range
      | slot < slotStart range || slot > slotEnd range = [range]
      | slotStart range == slotEnd range = []
      | slot == slotStart range = [range {slotStart = slot + 1}]
      | slot == slotEnd range = [range {slotEnd = slot - 1}]
      | otherwise =
          [ range {slotEnd = slot - 1}
          , range {slotStart = slot + 1}
          ]
