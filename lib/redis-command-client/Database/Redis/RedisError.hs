-- | Typed exceptions for Redis protocol and conversion errors.
--
-- @since 0.1.0.0
module Database.Redis.RedisError
  ( RedisError (..)
  ) where

import           Control.Exception   (Exception)
import           Data.Typeable       (Typeable)
import           Database.Redis.Resp (RespData)

-- | Typed exceptions for Redis protocol errors.
data RedisError
  = ParseError String        -- ^ RESP parse failure
  | ConnectionClosed         -- ^ Remote end closed the connection
  | UnexpectedResp RespData  -- ^ Unexpected RESP value during 'FromResp' conversion
  deriving (Eq, Show, Typeable)

instance Exception RedisError
