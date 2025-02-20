{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Resp where

import Control.Applicative ((<|>))
import Data.Attoparsec.ByteString qualified as StrictParse
import Data.Attoparsec.ByteString.Char8 qualified as Char8
import Data.Attoparsec.ByteString.Lazy qualified as Lazy
import Data.ByteString.Char8 qualified as B8
import Data.Map qualified as M
import Data.Set qualified as S
import Prelude hiding (take)

data RespData where
  RespSimpleString :: String -> RespData
  RespError :: String -> RespData
  RespInteger :: Integer -> RespData
  RespBulkString :: B8.ByteString -> RespData
  RespArray :: [RespData] -> RespData
  RespMap :: M.Map RespData RespData -> RespData
  RespSet :: S.Set RespData -> RespData
  deriving (Eq, Ord, Show)

class Encodable a where
  encode :: a -> B8.ByteString

instance Encodable RespData where
  encode :: RespData -> B8.ByteString
  encode (RespSimpleString s) = B8.concat ["+", B8.pack s, "\r\n"]
  encode (RespError s) = B8.concat ["-", B8.pack s, "\r\n"]
  encode (RespInteger i) = B8.concat [":", B8.pack . show $ i, "\r\n"]
  encode (RespBulkString s) = B8.concat ["$", B8.pack . show . B8.length $ s, "\r\n", s, "\r\n"]
  encode (RespArray xs) = B8.concat ["*", B8.pack . show $ length xs, "\r\n", mconcat . map encode $ xs]
  encode (RespSet s) = B8.concat ["~", B8.pack . show $ S.size s, "\r\n", mconcat . map encode $ S.toList s]
  encode (RespMap m) = B8.concat ["*", B8.pack . show $ M.size m, "\r\n", mconcat . map encodePair $ M.toList m]
    where
      encodePair (k, v) = B8.concat [encode k, encode v]

-- Parser for RespData
parseRespData :: Char8.Parser RespData
parseRespData =
  Char8.anyChar >>= \case
    '+' -> parseSimpleString
    '-' -> parseError
    ':' -> parseInteger
    '$' -> parseBulkString
    '*' -> parseArray
    '~' -> parseSet
    '%' -> parseMap
    _ -> fail "Invalid RESP data type"

parseSimpleString :: Char8.Parser RespData
parseSimpleString = do
  s <- Char8.manyTill Char8.anyChar Char8.endOfLine
  return $ RespSimpleString s

parseError :: Char8.Parser RespData
parseError = do
  s <- Char8.manyTill Char8.anyChar Char8.endOfLine
  return $ RespError s

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
  return $ RespBulkString s

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

parseWith :: (Monad m) => m B8.ByteString -> m RespData
parseWith recv = head <$> parseManyWith 1 recv

parseManyWith :: (Monad m) => Int -> m B8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  input <- recv
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> error err
    part@(StrictParse.Partial f) -> runUntilDone part recv
    StrictParse.Done _ r -> return r
  where
    runUntilDone :: (Monad m) => StrictParse.IResult i r -> m i -> m r
    runUntilDone (StrictParse.Fail _ _ err) _ = error err
    runUntilDone (StrictParse.Partial f) getMore = getMore >>= (flip runUntilDone getMore . f)
    runUntilDone (StrictParse.Done _ r) _ = return r