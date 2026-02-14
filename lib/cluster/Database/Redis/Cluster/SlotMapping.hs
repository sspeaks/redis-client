{-# LANGUAGE TemplateHaskell #-}

-- | Static mapping from Redis cluster hash slots to hash tags.
-- The mapping is fully resolved at compile time via Template Haskell,
-- so no parsing or file I/O occurs at runtime.
module Database.Redis.Cluster.SlotMapping
  ( SlotMapping
  , slotMappings
  ) where

import qualified Data.ByteString.Char8 as BS8
import           Data.FileEmbed        (embedFile)
import qualified Data.Map.Strict       as Map
import           Data.Vector           (Vector)
import qualified Data.Vector           as V
import           Data.Word             (Word16)

-- | Type alias for the slot-to-hash-tag lookup vector.
-- Index by slot number (0–16383) to get the corresponding hash tag 'ByteString'.
type SlotMapping = Vector BS8.ByteString

-- | Pre-computed mapping from slot number (0-16383) to hash tag.
-- The raw file is embedded at compile time; the Vector is constructed
-- once on first access and shared thereafter (top-level CAF).
{-# NOINLINE slotMappings #-}
slotMappings :: SlotMapping
slotMappings =
  let raw = $(embedFile "data/cluster_slot_mapping.txt")
      entries = map parseLine $ BS8.lines raw
      validEntries = [(slot, tag) | Just (slot, tag) <- entries]
      entryMap = Map.fromList validEntries
  in V.generate 16384 (\i -> Map.findWithDefault BS8.empty (fromIntegral i) entryMap)
  where
    parseLine :: BS8.ByteString -> Maybe (Word16, BS8.ByteString)
    parseLine line =
      case BS8.words line of
        [slotStr, tag] -> case reads (BS8.unpack slotStr) of
          [(slot, "")] -> Just (slot, tag)
          _            -> Nothing
        _ -> Nothing
