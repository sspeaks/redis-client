{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Resp where

import Control.Applicative ((<|>))
import Data.Attoparsec.ByteString qualified as StrictParse
import Data.Attoparsec.ByteString.Char8 qualified as Char8
import Data.Attoparsec.ByteString.Lazy qualified as Lazy
import Data.ByteString.Builder as Builder (Builder, byteString, lazyByteString)
import Data.ByteString.Char8 qualified as SB8
import Data.ByteString.Lazy.Char8 qualified as B8
import Data.Map qualified as M
import Data.Set qualified as S

data RespData where
  RespSimpleString :: String -> RespData
  RespError :: String -> RespData
  RespInteger :: Integer -> RespData
  RespBulkString :: B8.ByteString -> RespData
  RespNullBilkString :: RespData
  RespArray :: [RespData] -> RespData
  RespMap :: M.Map RespData RespData -> RespData
  RespSet :: S.Set RespData -> RespData
  deriving (Eq, Ord, Show)

class Encodable a where
  encode :: a -> Builder.Builder

instance Encodable RespData where
  encode :: RespData -> Builder.Builder
  encode (RespSimpleString !s) = Builder.lazyByteString $ B8.concat ["+", B8.pack s, "\r\n"]
  encode (RespError !s) = Builder.lazyByteString $ B8.concat ["-", B8.pack s, "\r\n"]
  encode (RespInteger !i) = Builder.lazyByteString $ B8.concat [":", B8.pack . show $ i, "\r\n"]
  encode (RespBulkString !s) = Builder.lazyByteString $ B8.concat ["$", B8.pack . show . B8.length $ s, "\r\n", s, "\r\n"]
  encode RespNullBilkString = Builder.lazyByteString $ "$-1\r\n"
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
  s <- Char8.takeTill (== '\r')
  _ <- Char8.take 2
  return $ RespSimpleString (SB8.unpack s)

parseError :: Char8.Parser RespData
parseError = do
  s <- Char8.takeTill (== '\r')
  _ <- Char8.take 2
  return $ RespError (SB8.unpack s)

parseInteger :: Char8.Parser RespData
parseInteger = do
  i <- Char8.signed Char8.decimal
  _ <- Char8.endOfLine
  return $ RespInteger i

parseBulkString :: Char8.Parser RespData
parseBulkString = do
  len <- Char8.decimal
  _ <- Char8.endOfLine
  s <- Char8.take len
  _ <- Char8.endOfLine
  return $ RespBulkString (B8.fromStrict s)

parseNullBulkString :: Char8.Parser RespData
parseNullBulkString = do
  _ <- Char8.char '-'
  _ <- Char8.char '1'
  _ <- Char8.endOfLine
  return RespNullBilkString

parseArray :: Char8.Parser RespData
parseArray = do
  len <- Char8.decimal
  _ <- Char8.endOfLine
  xs <- Char8.count len parseRespData
  return $ RespArray xs

parseSet :: Char8.Parser RespData
parseSet = do
  len <- Char8.decimal
  _ <- Char8.endOfLine
  xs <- Char8.count len parseRespData
  return $ RespSet (S.fromList xs)

parseMap :: Char8.Parser RespData
parseMap = do
  len <- Char8.decimal
  _ <- Char8.endOfLine
  pairs <- Char8.count len parsePair
  return $ RespMap (M.fromList pairs)
  where
    parsePair = do
      k <- parseRespData
      v <- parseRespData
      return (k, v)

parseWith :: (Monad m, MonadFail m) => m SB8.ByteString -> m RespData
parseWith recv = head <$> parseManyWith 1 recv

parseManyWith :: (Monad m, MonadFail m) => Int -> m SB8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  input <- recv
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> fail err
    part@(StrictParse.Partial f) -> runUntilDone part recv
    StrictParse.Done _ r -> return r
  where
    runUntilDone :: (Monad m, MonadFail m) => StrictParse.IResult i r -> m i -> m r
    runUntilDone (StrictParse.Fail _ _ err) _ = fail err
    runUntilDone (StrictParse.Partial f) getMore = getMore >>= (flip runUntilDone getMore . f)
    runUntilDone (StrictParse.Done _ r) _ = return r