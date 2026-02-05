module ClusterSlotMapping where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Vector as V
import           Data.Vector (Vector)
import           Data.Word (Word16)
import qualified Data.Map.Strict as Map
import           Cluster (ClusterNode, nodeSlotsServed, SlotRange(..))
import           System.IO.Unsafe (unsafePerformIO)

type SlotMapping = Vector BS.ByteString

{-# NOINLINE slotMappings #-}
slotMappings :: SlotMapping
slotMappings = unsafePerformIO $ do
  -- Hardcoded path as used in all previous call sites
  content <- readFile "cluster_slot_mapping.txt"
  let entries = map parseLine $ lines content
      validEntries = [(slot, tag) | Just (slot, tag) <- entries]
      entryMap = Map.fromList validEntries
  -- Create a vector of 16384 slots, empty ByteString for missing entries
  return $ V.generate 16384 (\i -> Map.findWithDefault BS.empty (fromIntegral i) entryMap)
  where
    parseLine :: String -> Maybe (Word16, BS.ByteString)
    parseLine line =
      case words line of
        [slotStr, tag] -> case reads slotStr of
          [(slot, "")] -> Just (slot, BSC.pack tag)
          _            -> Nothing
        _ -> Nothing

-- | Generates a key that maps to the specified slot using the global mappings.
-- The key format is "{hashtag}:<suffix>"
getKeyForSlot :: Word16 -> String -> BS.ByteString
getKeyForSlot slot suffix =
    let hashTag = slotMappings V.! fromIntegral slot
    in if BS.null hashTag
       then error $ "No hash tag found for slot " ++ show slot
       else BSC.pack $ "{" ++ BSC.unpack hashTag ++ "}:" ++ suffix

-- | Generates a key that maps to the specified node.
-- Examples:
-- getKeyForNode node "mykey"
getKeyForNode :: ClusterNode -> String -> BS.ByteString
getKeyForNode node suffix =
    case nodeSlotsServed node of
        [] -> error "Node serves no slots"
        (range:_) -> getKeyForSlot (slotStart range) suffix
