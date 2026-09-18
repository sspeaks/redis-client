{-# LANGUAGE OverloadedStrings #-}

-- | Typeclass for converting 'RespData' values into user-chosen Haskell types.
--
-- This module provides 'FromResp' together with a collection of instances for
-- common types so that Redis commands can return typed values instead of raw
-- 'RespData'.
--
-- @since 0.1.0.0
module Database.Redis.FromResp
  ( FromResp (..)
  ) where

import           Data.ByteString           (ByteString)
import           Data.Text                 (Text)
import qualified Data.Text.Encoding        as TE
import           Database.Redis.RedisError (RedisClientError (..))
import           Database.Redis.Resp       (RespData (..))

-- | Convert a 'RespData' value to a Haskell type.
--
-- Redis error replies are always returned as 'RedisServerError'. Other
-- incompatible values are returned as 'RedisConversionError'.
class FromResp a where
  fromResp :: RespData -> Either RedisClientError a

-- | Identity instance – always succeeds.
instance FromResp RespData where
  fromResp :: RespData -> Either RedisClientError RespData
  fromResp = rejectServerError

-- | Extracts the payload of 'RespBulkString' or 'RespSimpleString'.
instance FromResp ByteString where
  fromResp :: RespData -> Either RedisClientError ByteString
  fromResp (RespError message)   = Left $ RedisServerError message
  fromResp (RespBulkString bs)   = Right bs
  fromResp (RespSimpleString bs) = Right bs
  fromResp rd                    = Left (RedisConversionError rd)

-- | 'Nothing' for 'RespNullBulkString', otherwise delegates to the 'ByteString' instance.
instance FromResp (Maybe ByteString) where
  fromResp :: RespData -> Either RedisClientError (Maybe ByteString)
  fromResp RespNullBulkString = Right Nothing
  fromResp rd                 = Just <$> fromResp rd

-- | Extracts 'RespInteger' payload.
instance FromResp Integer where
  fromResp :: RespData -> Either RedisClientError Integer
  fromResp (RespError message) = Left $ RedisServerError message
  fromResp (RespInteger i)     = Right i
  fromResp rd                  = Left (RedisConversionError rd)

-- | Interprets @RespSimpleString \"OK\"@ and @RespInteger 1@ as 'True',
-- @RespInteger 0@ as 'False'.
instance FromResp Bool where
  fromResp :: RespData -> Either RedisClientError Bool
  fromResp (RespError message)     = Left $ RedisServerError message
  fromResp (RespSimpleString "OK") = Right True
  fromResp (RespInteger 1)         = Right True
  fromResp (RespInteger 0)         = Right False
  fromResp rd                      = Left (RedisConversionError rd)

-- | Extracts each element of a 'RespArray' as a 'ByteString'.
instance FromResp [ByteString] where
  fromResp :: RespData -> Either RedisClientError [ByteString]
  fromResp (RespError message) = Left $ RedisServerError message
  fromResp (RespArray xs)      = traverse fromResp xs
  fromResp rd                  = Left (RedisConversionError rd)

-- | Extracts each element of a 'RespArray' as 'RespData'.
instance FromResp [RespData] where
  fromResp :: RespData -> Either RedisClientError [RespData]
  fromResp (RespError message) = Left $ RedisServerError message
  fromResp (RespArray xs)      = Right xs
  fromResp rd                  = Left (RedisConversionError rd)

-- | Discards successful responses without hiding Redis error replies.
instance FromResp () where
  fromResp :: RespData -> Either RedisClientError ()
  fromResp (RespError message) = Left $ RedisServerError message
  fromResp _                   = Right ()

-- | UTF-8 decode a 'ByteString' payload into 'Text'.
instance FromResp Text where
  fromResp :: RespData -> Either RedisClientError Text
  fromResp rd = case fromResp rd of
    Right (bs :: ByteString) -> case TE.decodeUtf8' bs of
      Right t -> Right t
      Left _  -> Left (RedisConversionError rd)
    Left e -> Left e

-- | 'Nothing' for 'RespNullBulkString', otherwise delegates to the 'Text' instance.
instance FromResp (Maybe Text) where
  fromResp :: RespData -> Either RedisClientError (Maybe Text)
  fromResp RespNullBulkString = Right Nothing
  fromResp rd                 = Just <$> fromResp rd

rejectServerError :: RespData -> Either RedisClientError RespData
rejectServerError (RespError message) = Left $ RedisServerError message
rejectServerError response            = Right response
