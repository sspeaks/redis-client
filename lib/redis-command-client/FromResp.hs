{-# LANGUAGE OverloadedStrings #-}

-- | Typeclass for converting 'RespData' values into user-chosen Haskell types.
--
-- This module provides 'FromResp' together with a collection of instances for
-- common types so that Redis commands can return typed values instead of raw
-- 'RespData'.
--
-- @since 0.1.0.0
module FromResp
  ( FromResp (..)
  ) where

import           Data.ByteString     (ByteString)
import           Data.Text           (Text)
import qualified Data.Text.Encoding  as TE
import           Database.Redis.Resp (RespData (..))
import           RedisError          (RedisError (..))

-- | Convert a 'RespData' value to a Haskell type.
--
-- Returns @Left (UnexpectedResp rd)@ when the conversion cannot be performed
-- for the given RESP value @rd@.
class FromResp a where
  fromResp :: RespData -> Either RedisError a

-- | Identity instance – always succeeds.
instance FromResp RespData where
  fromResp :: RespData -> Either RedisError RespData
  fromResp = Right

-- | Extracts the payload of 'RespBulkString' or 'RespSimpleString'.
instance FromResp ByteString where
  fromResp :: RespData -> Either RedisError ByteString
  fromResp (RespBulkString bs)   = Right bs
  fromResp (RespSimpleString bs) = Right bs
  fromResp rd                    = Left (UnexpectedResp rd)

-- | 'Nothing' for 'RespNullBulkString', otherwise delegates to the 'ByteString' instance.
instance FromResp (Maybe ByteString) where
  fromResp :: RespData -> Either RedisError (Maybe ByteString)
  fromResp RespNullBulkString = Right Nothing
  fromResp rd                 = Just <$> fromResp rd

-- | Extracts 'RespInteger' payload.
instance FromResp Integer where
  fromResp :: RespData -> Either RedisError Integer
  fromResp (RespInteger i) = Right i
  fromResp rd              = Left (UnexpectedResp rd)

-- | Interprets @RespSimpleString \"OK\"@ and @RespInteger 1@ as 'True',
-- @RespInteger 0@ as 'False'.
instance FromResp Bool where
  fromResp :: RespData -> Either RedisError Bool
  fromResp (RespSimpleString "OK") = Right True
  fromResp (RespInteger 1)         = Right True
  fromResp (RespInteger 0)         = Right False
  fromResp rd                      = Left (UnexpectedResp rd)

-- | Extracts each element of a 'RespArray' as a 'ByteString'.
instance FromResp [ByteString] where
  fromResp :: RespData -> Either RedisError [ByteString]
  fromResp (RespArray xs) = traverse fromResp xs
  fromResp rd             = Left (UnexpectedResp rd)

-- | Extracts each element of a 'RespArray' as 'RespData'.
instance FromResp [RespData] where
  fromResp :: RespData -> Either RedisError [RespData]
  fromResp (RespArray xs) = Right xs
  fromResp rd             = Left (UnexpectedResp rd)

-- | Always succeeds, discarding the response.
instance FromResp () where
  fromResp :: RespData -> Either RedisError ()
  fromResp _ = Right ()

-- | UTF-8 decode a 'ByteString' payload into 'Text'.
instance FromResp Text where
  fromResp :: RespData -> Either RedisError Text
  fromResp rd = case fromResp rd of
    Right (bs :: ByteString) -> case TE.decodeUtf8' bs of
      Right t -> Right t
      Left _  -> Left (UnexpectedResp rd)
    Left e -> Left e

-- | 'Nothing' for 'RespNullBulkString', otherwise delegates to the 'Text' instance.
instance FromResp (Maybe Text) where
  fromResp :: RespData -> Either RedisError (Maybe Text)
  fromResp RespNullBulkString = Right Nothing
  fromResp rd                 = Just <$> fromResp rd
