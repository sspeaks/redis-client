{-# LANGUAGE OverloadedStrings #-}

-- | Helpers for generating keys that map to specific cluster slots or nodes.
-- Used by the CLI fill tool and tests, not part of the library API.
module SlotMappingHelpers
  ( getKeyForSlot
  , getKeyForNode
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Vector as V
import           Data.Word (Word16)
import           Cluster (ClusterNode, nodeSlotsServed, SlotRange (..))
import           ClusterSlotMapping (slotMappings)

-- | Generates a key that maps to the specified slot using the global mappings.
-- The key format is "{hashtag}:<suffix>"
getKeyForSlot :: Word16 -> String -> BS.ByteString
getKeyForSlot slot suffix =
    let hashTag = slotMappings V.! fromIntegral slot
    in if BS.null hashTag
       then error $ "No hash tag found for slot " ++ show slot
       else BSC.pack $ "{" ++ BSC.unpack hashTag ++ "}:" ++ suffix

-- | Generates a key that maps to the specified node.
getKeyForNode :: ClusterNode -> String -> BS.ByteString
getKeyForNode node suffix =
    case nodeSlotsServed node of
        [] -> error "Node serves no slots"
        (range:_) -> getKeyForSlot (slotStart range) suffix
