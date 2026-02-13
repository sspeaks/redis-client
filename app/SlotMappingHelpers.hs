{-# LANGUAGE OverloadedStrings #-}

-- | Helpers for generating keys that map to specific cluster slots or nodes.
-- Used by the CLI fill tool and tests, not part of the library API.
module SlotMappingHelpers
  ( getKeyForNode
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Vector as V
import           Cluster (ClusterNode, nodeSlotsServed, SlotRange (..))
import           ClusterSlotMapping (slotMappings)

-- | Generates a key that maps to the specified slot using the global mappings.
-- The key format is "{hashtag}:<suffix>"
getKeyForSlot :: SlotRange -> String -> BS.ByteString
getKeyForSlot range suffix =
    let hashTag = slotMappings V.! fromIntegral (slotStart range)
    in if BS.null hashTag
       then error $ "No hash tag found for slot " ++ show (slotStart range)
       else BS8.pack $ "{" ++ BS8.unpack hashTag ++ "}:" ++ suffix

-- | Generates a key that maps to the specified node.
getKeyForNode :: ClusterNode -> String -> BS.ByteString
getKeyForNode node suffix =
    case nodeSlotsServed node of
        [] -> error "Node serves no slots"
        (range:_) -> getKeyForSlot range suffix
