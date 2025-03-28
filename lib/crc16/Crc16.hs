module Crc16  ( crc16 ) where

import           Data.ByteString       (ByteString)
import qualified Data.ByteString.Char8 as BS
import           Data.Word             (Word16)
import           Foreign.C.String      (CString, withCString)
import           Foreign.C.Types       (CInt (..), CUShort (..))

-- Foreign function interface to the C function
foreign import ccall "crc16" c_crc16 :: CString -> CInt -> IO CUShort

-- Haskell wrapper for the C function
crc16 :: ByteString -> IO Word16
crc16 bs = BS.useAsCStringLen bs $ \(cstr, len) -> do
  result <- c_crc16 cstr (fromIntegral len)
  return (fromIntegral result `mod` 2^14)
