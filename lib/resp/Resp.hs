{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Resp where

import           Control.Applicative              ((<|>))
import qualified Data.Attoparsec.ByteString       as StrictParse
import qualified Data.Attoparsec.ByteString.Char8 as Char8
import qualified Data.Attoparsec.ByteString.Lazy  as Lazy
import           Data.ByteString.Builder          as Builder (Builder,
                                                              byteString,
                                                              lazyByteString)
import qualified Data.ByteString.Char8            as SB8
import qualified Data.ByteString.Lazy             as BS
import qualified Data.ByteString.Lazy.Char8       as B8
import qualified Data.Map                         as M
import qualified Data.Set                         as S
import qualified Data.String                      as BS

data RespData where
  RespSimpleString :: !String -> RespData
  RespError :: !String -> RespData
  RespInteger :: !Integer -> RespData
  RespBulkString :: !B8.ByteString -> RespData
  RespNullBulkString :: RespData
  RespArray :: ![RespData] -> RespData
  RespMap :: !(M.Map RespData RespData) -> RespData
  RespSet :: !(S.Set RespData) -> RespData
  deriving (Eq, Ord)

instance Show RespData where
  show :: RespData -> String
  show = B8.unpack . byteShow

byteShow :: RespData -> BS.ByteString
byteShow (RespSimpleString !s) = BS.fromString s
byteShow (RespError !s) = "ERROR: " <> BS.fromString s
byteShow (RespInteger !i) = BS.fromString . show $ i
byteShow (RespBulkString !s) = s
byteShow RespNullBulkString = "NULL"
byteShow (RespArray !xs) = BS.intercalate "\n" (map byteShow xs)
byteShow (RespSet !s) = BS.intercalate "\n" (map byteShow (S.toList s))
byteShow (RespMap !m) = BS.intercalate "\n" (map showPair (M.toList m))
  where
    showPair (k, v) = byteShow k <> ": " <> byteShow v

class Encodable a where
  encode :: a -> Builder.Builder

instance Encodable RespData where
  encode :: RespData -> Builder.Builder
  encode (RespSimpleString !s) = Builder.lazyByteString $ B8.concat ["+", B8.pack s, "\r\n"]
  encode (RespError !s) = Builder.lazyByteString $ B8.concat ["-", B8.pack s, "\r\n"]
  encode (RespInteger !i) = Builder.lazyByteString $ B8.concat [":", B8.pack . show $ i, "\r\n"]
  encode (RespBulkString !s) = Builder.lazyByteString $ B8.concat ["$", B8.pack . show . B8.length $ s, "\r\n", s, "\r\n"]
  encode RespNullBulkString = Builder.lazyByteString "$-1\r\n"
  encode (RespArray !xs) = Builder.lazyByteString (B8.concat ["*", B8.pack . show $ length xs, "\r\n"]) <> foldMap encode xs
  encode (RespSet !s) = Builder.lazyByteString (B8.concat ["~", B8.pack . show $ S.size s, "\r\n"]) <> foldMap encode (S.toList s)
  encode (RespMap !m) = Builder.lazyByteString (B8.concat ["*", B8.pack . show $ M.size m, "\r\n"]) <> foldMap encodePair (M.toList m)
    where
      encodePair (k, v) = encode k <> encode v

-- Parser for RespData
parseRespData :: Char8.Parser RespData
parseRespData =
  Char8.anyChar >>= \case
    '+' -> parseSimpleString
    '-' -> parseError
    ':' -> parseInteger
    '$' -> parseBulkString <|> parseNullBulkString
    '*' -> parseArray
    '~' -> parseSet
    '%' -> parseMap
    v -> do
      rest <- Char8.takeByteString
      let catted = SB8.cons v rest
      fail ("Invalid RESP data type: Remaining string " <> SB8.unpack catted)

parseSimpleString :: Char8.Parser RespData
parseSimpleString = do
  !s <- Char8.takeTill (== '\r')
  _ <- Char8.take 2
  return $ RespSimpleString (SB8.unpack s)

parseError :: Char8.Parser RespData
parseError = do
  !s <- Char8.takeTill (== '\r')
  _ <- Char8.take 2
  return $ RespError (SB8.unpack s)

parseInteger :: Char8.Parser RespData
parseInteger = do
  !i <- Char8.signed Char8.decimal
  _ <- Char8.endOfLine
  return $ RespInteger i

parseBulkString :: Char8.Parser RespData
parseBulkString = do
  !len <- Char8.decimal
  _ <- Char8.endOfLine
  !s <- Char8.take len
  _ <- Char8.endOfLine
  return $ RespBulkString (B8.fromStrict s)

parseNullBulkString :: Char8.Parser RespData
parseNullBulkString = do
  _ <- Char8.char '-'
  _ <- Char8.char '1'
  _ <- Char8.endOfLine
  return RespNullBulkString

parseArray :: Char8.Parser RespData
parseArray = do
  !len <- Char8.decimal
  _ <- Char8.endOfLine
  !xs <- Char8.count len parseRespData
  return $ RespArray xs

parseSet :: Char8.Parser RespData
parseSet = do
  !len <- Char8.decimal
  _ <- Char8.endOfLine
  !xs <- Char8.count len parseRespData
  return $ RespSet (S.fromList xs)

parseMap :: Char8.Parser RespData
parseMap = do
  !len <- Char8.decimal
  _ <- Char8.endOfLine
  !pairs <- Char8.count len parsePair
  return $ RespMap (M.fromList pairs)
  where
    parsePair = do
      k <- parseRespData
      v <- parseRespData
      return (k, v)

-- | Parse strict ByteString into RespData
parseStrict :: SB8.ByteString -> Either String RespData
parseStrict = StrictParse.parseOnly parseRespData
