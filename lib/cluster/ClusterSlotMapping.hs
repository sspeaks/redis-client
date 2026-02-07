{-# LANGUAGE TemplateHaskell #-}

-- | Static mapping from Redis cluster hash slots to hash tags.
-- The mapping is fully resolved at compile time via Template Haskell,
-- so no parsing or file I/O occurs at runtime.
module ClusterSlotMapping
  ( SlotMapping
  , slotMappings
  ) where

import qualified Data.ByteString.Char8 as BSC
import           Data.FileEmbed (embedFile)
import qualified Data.Vector as V
import           Data.Vector (Vector)
import qualified Data.Map.Strict as Map
import           Data.Word (Word16)

-- | Type alias for the slot-to-hash-tag lookup vector.
-- Index by slot number (0–16383) to get the corresponding hash tag 'ByteString'.
type SlotMapping = Vector BSC.ByteString

-- | Pre-computed mapping from slot number (0-16383) to hash tag.
-- The raw file is embedded at compile time; the Vector is constructed
-- once on first access and shared thereafter (top-level CAF).
{-# NOINLINE slotMappings #-}
slotMappings :: SlotMapping
slotMappings =
  let raw = $(embedFile "data/cluster_slot_mapping.txt")
      entries = map parseLine $ BSC.lines raw
      validEntries = [(slot, tag) | Just (slot, tag) <- entries]
      entryMap = Map.fromList validEntries
  in V.generate 16384 (\i -> Map.findWithDefault BSC.empty (fromIntegral i) entryMap)
  where
    parseLine :: BSC.ByteString -> Maybe (Word16, BSC.ByteString)
    parseLine line =
      case BSC.words line of
        [slotStr, tag] -> case reads (BSC.unpack slotStr) of
          [(slot, "")] -> Just (slot, tag)
          _            -> Nothing
        _ -> Nothing
