{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Resp where

import Data.ByteString.Char8 qualified as B
import Data.Map qualified as M
import Data.Set qualified as S

data RespData where
  RespSimpleString :: String -> RespData
  RespError :: String -> RespData
  RespInteger :: Integer -> RespData
  RespBulkString :: B.ByteString -> RespData
  RespArray :: [RespData] -> RespData
  RespMap :: M.Map RespData RespData -> RespData
  RespSet :: S.Set RespData -> RespData
  deriving (Eq, Ord, Show)

class Encodable a where
  encode :: a -> B.ByteString

instance Encodable RespData where
  encode :: RespData -> B.ByteString
  encode (RespSimpleString s) = B.concat ["+", B.pack s, "\r\n"]
  encode (RespError s) = B.concat ["-", B.pack s, "\r\n"]
  encode (RespInteger i) = B.concat [":", B.pack . show $ i, "\r\n"]
  encode (RespBulkString s) = B.concat ["$", B.pack . show . B.length $ s, "\r\n", s, "\r\n"]
  encode (RespArray xs) = B.concat ["*", B.pack . show $ length xs, "\r\n", mconcat . map encode $ xs]
  encode (RespSet s) = B.concat ["~", B.pack . show $ S.size s, "\r\n", mconcat . map encode $ S.toList s]
  encode (RespMap m) = B.concat ["*", B.pack . show $ M.size m, "\r\n", mconcat . map encodePair $ M.toList m]
    where
      encodePair (k, v) = B.concat [encode k, encode v]