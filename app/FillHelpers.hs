{-# LANGUAGE OverloadedStrings #-}

module FillHelpers
  ( generateBytes
  , generateBytesWithHashTag
  , randomNoise
  ) where

import qualified Data.ByteString            as BS
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Lazy       as LB
import           Data.Bits                  (shiftR)
import           Data.Word                  (Word64, Word8)

-- 128MB of pre-computed random noise (larger buffer reduces collision probability)
-- Uses unfoldrN to generate directly into a buffer, avoiding the ~5GB overhead 
-- of constructing an intermediate [Word8] list.
randomNoise :: BS.ByteString
randomNoise = fst $ BS.unfoldrN (128 * 1024 * 1024) step 0
  where
    step :: Word64 -> Maybe (Word8, Word64)
    step !s = Just (fromIntegral (s `shiftR` 56), s * 6364136223846793005 + 1442695040888963407)
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
      let !scrambled = s * 6364136223846793005 + 1442695040888963407
          !noiseSize = size - 8
          -- Ensure we don't exceed the noise buffer size
          !bufferSize = 128 * 1024 * 1024
          !safeNoiseSize = min noiseSize bufferSize
          !offset = fromIntegral (scrambled `rem` (fromIntegral (bufferSize - safeNoiseSize)))
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
          !prefixLen = 2 + tagLen + 1  -- { + tag + }:
          !totalPrefix = prefixLen + 8  -- prefix + 8-byte seed
      in if totalPrefix > size
         then generateBytes size seed  -- Fall back if prefix too large
         else 
           let !paddingNeeded = size - totalPrefix
               !scrambled = seed * 6364136223846793005 + 1442695040888963407
               !bufferSize = 128 * 1024 * 1024
               !safePaddingSize = min paddingNeeded bufferSize
               !offset = fromIntegral (scrambled `rem` (fromIntegral (bufferSize - safePaddingSize)))
               !padding = BS.take paddingNeeded (BS.drop offset randomNoise)
           in prefix <> Builder.word64LE seed <> Builder.byteString padding
{-# INLINE generateBytesWithHashTag #-}
