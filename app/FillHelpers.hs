{-# LANGUAGE OverloadedStrings #-}

module FillHelpers
  ( generateBytes
  , generateBytesWithHashTag
  , randomNoise
  , lcgMultiplier
  , lcgIncrement
  , nextLCG
  , threadSeedSpacing
  ) where

import           Data.Bits               (shiftR)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as LB
import           Data.Word               (Word64, Word8)

-- 128MB of pre-computed random noise (larger buffer reduces collision probability)
-- Uses unfoldrN to generate directly into a buffer, avoiding the ~5GB overhead
-- of constructing an intermediate [Word8] list.
randomNoise :: BS.ByteString
randomNoise = fst $ BS.unfoldrN (128 * 1024 * 1024) step 0
  where
    step :: Word64 -> Maybe (Word8, Word64)
    step !s = Just (fromIntegral (s `shiftR` 56), nextLCG s)
{-# NOINLINE randomNoise #-}

-- | Generate arbitrary number of bytes efficiently
-- Uses 8-byte seed followed by random noise from the shared buffer
generateBytes :: Int -> Word64 -> Builder.Builder
generateBytes size !s
  | size <= 8 =
      -- For very small keys, just use the seed bytes
      let seedBS = LB.toStrict $ Builder.toLazyByteString (Builder.word64LE s)
      in Builder.byteString (BS.take size seedBS)
  | otherwise =
      -- For larger keys, use seed + noise
      let !scrambled = nextLCG s
          !noiseSize = size - 8
          -- Ensure we don't exceed the noise buffer size
          !bufferSize = 128 * 1024 * 1024
          !safeNoiseSize = min noiseSize bufferSize
          !offset = fromIntegral (scrambled `rem` fromIntegral (bufferSize - safeNoiseSize))
          !chunk = BS.take noiseSize (BS.drop offset randomNoise)
      in Builder.word64LE s <> Builder.byteString chunk
{-# INLINE generateBytes #-}

-- | Generate bytes with hash tag prefix for cluster routing
-- Falls back to regular generation if hash tag is empty or too large for the key size
generateBytesWithHashTag :: Int -> BS.ByteString -> Word64 -> Builder.Builder
generateBytesWithHashTag size hashTag !seed
  | BS.null hashTag = generateBytes size seed
  | otherwise =
      let !tagLen = BS.length hashTag
          -- Format: {hashtag}:seed:padding
          !prefix = Builder.char8 '{' <> Builder.byteString hashTag <> Builder.stringUtf8 "}:"
          !prefixOverhead = 3  -- { + } + :
          !totalPrefixLen = prefixOverhead + tagLen + 8  -- prefix chars + tag + 8-byte seed
      in if totalPrefixLen > size
         then generateBytes size seed  -- Fall back if prefix too large
         else
           let !paddingNeeded = size - totalPrefixLen
               !scrambled = nextLCG seed
               !bufferSize = 128 * 1024 * 1024
               !safePaddingSize = min paddingNeeded bufferSize
               !offset = fromIntegral (scrambled `rem` fromIntegral (bufferSize - safePaddingSize))
               !padding = BS.take paddingNeeded (BS.drop offset randomNoise)
           in prefix <> Builder.word64LE seed <> Builder.byteString padding
{-# INLINE generateBytesWithHashTag #-}

-- | LCG multiplier (PCG-family constant)
lcgMultiplier :: Word64
lcgMultiplier = 6364136223846793005
{-# INLINE lcgMultiplier #-}

-- | LCG increment (PCG-family constant)
lcgIncrement :: Word64
lcgIncrement = 1442695040888963407
{-# INLINE lcgIncrement #-}

-- | Advance the LCG state by one step
nextLCG :: Word64 -> Word64
nextLCG !s = s * lcgMultiplier + lcgIncrement
{-# INLINE nextLCG #-}

-- | Spacing between seeds for different threads to prevent overlap (1 billion keys ~ 1TB data)
threadSeedSpacing :: Word64
threadSeedSpacing = 1000000000
