{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Resp where

import Data.ByteString.Char8 qualified as B

data RespData a where
  RespSimpleString :: String -> RespData String
  RespError :: String -> RespData String
  RespInteger :: Integer -> RespData Integer
  RespBulkString :: B.ByteString -> RespData B.ByteString

class Encodable a where
  encode :: a -> B.ByteString

instance Encodable (RespData a) where
  encode :: RespData a -> B.ByteString
  encode (RespSimpleString s) = B.concat ["+", B.pack s, "\r\n"]
  encode (RespError s) = B.concat ["-", B.pack s, "\r\n"]
  encode (RespInteger i) = B.concat [":", B.pack . show $ i, "\r\n"]
  encode (RespBulkString s) = B.concat ["$", B.pack . show . B.length $ s, "\r\n", s, "\r\n"]