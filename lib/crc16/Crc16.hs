-- | CRC16 hash computation for Redis cluster slot assignment.
-- Wraps a C implementation via FFI. The FFI call is safe to treat as pure
-- (deterministic, no side effects), so we use 'unsafeDupablePerformIO' to
-- avoid forcing callers into IO on the hot path.
module Crc16  ( crc16 ) where

import           Data.Bits             ((.&.))
import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS8
import           Data.Word             (Word16)
import           Foreign.C.String      (CString)
import           Foreign.C.Types       (CInt (..), CUShort (..))
import           System.IO.Unsafe      (unsafeDupablePerformIO)

-- Foreign function interface to the C function (marked unsafe for speed — no callbacks)
foreign import ccall unsafe "crc16" c_crc16 :: CString -> CInt -> CUShort

-- | Compute the CRC16 hash of a key, reduced to the Redis cluster slot range (0–16383).
-- Pure: the underlying C function is deterministic with no side effects.
crc16 :: ByteString -> Word16
crc16 bs = unsafeDupablePerformIO $
  BS8.useAsCStringLen bs $ \(cstr, len) -> do
    let !result = c_crc16 cstr (fromIntegral len)
    return $! fromIntegral result .&. (0x3FFF :: Word16)
{-# INLINE crc16 #-}
