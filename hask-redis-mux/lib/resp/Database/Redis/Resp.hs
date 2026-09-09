{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Serialization and parsing for the Redis Serialization Protocol (RESP).
-- Supports RESP2 and RESP3 wire types including bulk strings, arrays, maps, and sets.
--
-- @since 0.1.0.0
module Database.Redis.Resp
  ( RespData (..)
  , Encodable (..)
  , parseRespData
  , parseStrict
  ) where

import           Control.Applicative              ((<|>))
import qualified Data.Attoparsec.ByteString       as StrictParse
import qualified Data.Attoparsec.ByteString.Char8 as Char8
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as BS8
import qualified Data.Map                         as M
import qualified Data.Set                         as S

-- | A value in the RESP wire protocol. Each constructor corresponds to a RESP type prefix.
data RespData where
  RespSimpleString :: !ByteString -> RespData
  RespError :: !ByteString -> RespData
  RespInteger :: !Integer -> RespData
  RespBulkString :: !ByteString -> RespData
  RespNullBulkString :: RespData
  RespArray :: ![RespData] -> RespData
  RespMap :: !(M.Map RespData RespData) -> RespData
  RespSet :: !(S.Set RespData) -> RespData
  deriving (Eq, Ord)

instance Show RespData where
  show :: RespData -> String
  show = BS8.unpack . byteShow

byteShow :: RespData -> ByteString
byteShow (RespSimpleString !s) = s
byteShow (RespError !s) = "ERROR: " <> s
byteShow (RespInteger !i) = BS8.pack . show $ i
byteShow (RespBulkString !s) = s
byteShow RespNullBulkString = "NULL"
byteShow (RespArray !xs) = BS8.intercalate "\n" (map byteShow xs)
byteShow (RespSet !s) = BS8.intercalate "\n" (map byteShow (S.toList s))
byteShow (RespMap !m) = BS8.intercalate "\n" (map showPair (M.toList m))
  where
    showPair (k, v) = byteShow k <> ": " <> byteShow v

-- | Types that can be serialized to the RESP wire format.
class Encodable a where
  encode :: a -> Builder.Builder

instance Encodable RespData where
  encode :: RespData -> Builder.Builder
  encode (RespSimpleString !s) = Builder.char8 '+' <> Builder.byteString s <> Builder.byteString "\r\n"
  encode (RespError !s) = Builder.char8 '-' <> Builder.byteString s <> Builder.byteString "\r\n"
  encode (RespInteger !i) = Builder.char8 ':' <> Builder.integerDec i <> Builder.byteString "\r\n"
  encode (RespBulkString !s) = Builder.char8 '$' <> Builder.intDec (BS8.length s) <> Builder.byteString "\r\n" <> Builder.byteString s <> Builder.byteString "\r\n"
  encode RespNullBulkString = Builder.byteString "$-1\r\n"
  encode (RespArray !xs) = Builder.char8 '*' <> Builder.intDec (length xs) <> Builder.byteString "\r\n" <> foldMap encode xs
  encode (RespSet !s) = Builder.char8 '~' <> Builder.intDec (S.size s) <> Builder.byteString "\r\n" <> foldMap encode (S.toList s)
  encode (RespMap !m) = Builder.char8 '%' <> Builder.intDec (M.size m) <> Builder.byteString "\r\n" <> foldMap encodePair (M.toList m)
    where
      encodePair (k, v) = encode k <> encode v

-- | Attoparsec parser for a single RESP value. Can be composed with other parsers
-- or used with 'parseStrict' for one-shot parsing.
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
      let catted = BS8.cons v rest
      fail ("Invalid RESP data type: Remaining string " <> BS8.unpack catted)
{-# INLINE parseRespData #-}

parseSimpleString :: Char8.Parser RespData
parseSimpleString = do
  !s <- parseLine
  return $ RespSimpleString s
{-# INLINE parseSimpleString #-}

parseError :: Char8.Parser RespData
parseError = do
  !s <- parseLine
  return $ RespError s
{-# INLINE parseError #-}

parseInteger :: Char8.Parser RespData
parseInteger = do
  !i <- Char8.signed Char8.decimal
  parseCRLF
  return $ RespInteger i
{-# INLINE parseInteger #-}

parseBulkString :: Char8.Parser RespData
parseBulkString = do
  !len <- Char8.decimal
  parseCRLF
  !s <- Char8.take len
  parseCRLF
  return $ RespBulkString s
{-# INLINE parseBulkString #-}

parseNullBulkString :: Char8.Parser RespData
parseNullBulkString = do
  _ <- Char8.char '-'
  _ <- Char8.char '1'
  parseCRLF
  return RespNullBulkString

parseArray :: Char8.Parser RespData
parseArray = do
  !len <- Char8.decimal
  parseCRLF
  !xs <- Char8.count len parseRespData
  return $ RespArray xs

parseSet :: Char8.Parser RespData
parseSet = do
  !len <- Char8.decimal
  parseCRLF
  !xs <- Char8.count len parseRespData
  return $ RespSet (S.fromList xs)

parseMap :: Char8.Parser RespData
parseMap = do
  !len <- Char8.decimal
  parseCRLF
  !pairs <- Char8.count len parsePair
  return $ RespMap (M.fromList pairs)
  where
    parsePair = do
      k <- parseRespData
      v <- parseRespData
      return (k, v)

parseLine :: Char8.Parser ByteString
parseLine = do
  !line <- Char8.takeTill (\c -> c == '\r' || c == '\n')
  parseCRLF
  return line
{-# INLINE parseLine #-}

parseCRLF :: Char8.Parser ()
parseCRLF = do
  _ <- Char8.char '\r'
  _ <- Char8.char '\n'
  return ()
{-# INLINE parseCRLF #-}

-- | Parse exactly one complete RESP value with no trailing bytes.
parseStrict :: BS8.ByteString -> Either String RespData
parseStrict = StrictParse.parseOnly (parseRespData <* StrictParse.endOfInput)
