# Cluster Slot Mapping Data File

## Overview

`cluster_slot_mapping.txt` is a flat data file containing mappings from Redis cluster slot numbers to short strings that hash to those slots.

## Format

The file contains 16,384 lines (one for each Redis cluster slot, 0-16383), with each line containing:
```
<slot_number> <string>
```

For example:
```
0 fHh
1 d9C
2 aVD
...
16383 apX
```

## Purpose

This file provides a pre-computed mapping of cluster slot numbers to short (3-character) strings where each string's CRC16 hash (mod 16384) equals its corresponding slot number. This can be useful for:

- Testing Redis cluster slot routing
- Generating test data that targets specific slots
- Benchmarking cluster operations with predictable slot distributions

## Verification

The mapping has been verified using both:
1. Python implementation of the CRC16 algorithm
2. Haskell implementation using the actual `crc16` module from this codebase

All 16,384 mappings have been verified to be correct.

## Properties

- All strings are exactly 3 characters long
- Strings use alphanumeric characters (a-z, A-Z, 0-9)
- Each slot from 0 to 16383 has exactly one string
- Each string maps to exactly one slot

## Loading in Haskell

To load this file in Haskell code:

```haskell
import qualified Data.ByteString.Char8 as BS
import qualified Data.Vector as V
import Data.Word (Word16)

loadSlotMapping :: FilePath -> IO (V.Vector BS.ByteString)
loadSlotMapping path = do
  content <- readFile path
  let entries = lines content
      slots = V.fromList $ map (BS.pack . last . words) entries
  return slots

-- Usage:
-- mapping <- loadSlotMapping "cluster_slot_mapping.txt"
-- let stringForSlot100 = mapping V.! 100  -- "fUA"
```
