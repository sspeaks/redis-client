{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client
import Data.ByteString.Char8 qualified as BSC
import Resp

maxRecvBytes :: Int
maxRecvBytes = 4096

main :: IO ()
main = do
  conClient <- connect (NotConnectedTLSClient "sspeaks-swec-test-cust-appr.cache.icbbvt.windows-int.net" Nothing)
  print ("Socket connected" :: String)
  send conClient "HELLO 3 AUTH default <password>\r\n"
  parseWith (recieve conClient) >>= print
  send conClient "PING\r\n"
  parseWith (recieve conClient) >>= print
  send conClient (encode (RespArray [RespBulkString "SET", RespBulkString "key", RespBulkString "value"])) >>= print
  parseWith (recieve conClient) >>= print
  send conClient (encode (RespArray [RespBulkString "GET", RespBulkString "key"])) >>= print
  parseWith (recieve conClient) >>= print
  let sendVal = mconcat $ map (\a -> encode (RespArray [RespBulkString "SET", RespBulkString ("key" <> BSC.pack (show a)), RespBulkString ("value" <> BSC.pack (show a))])) ([0 .. 100] :: [Integer])
  send conClient sendVal >>= print
  parseManyWith 101 (recieve conClient) >>= print
  let getVal = mconcat $ map (\a -> encode (RespArray [RespBulkString "GET", RespBulkString ("key" <> BSC.pack (show a))])) ([0 .. 100] :: [Integer])
  send conClient getVal >>= print
  parseManyWith 101 (recieve conClient) >>= print
  close conClient
  return ()
