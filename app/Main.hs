{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client
import Control.Monad (replicateM_)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BS
import Data.Default.Class (def)
import Network.TLS
import Network.TLS.Extra.Cipher
import Resp (RespData (RespArray, RespBulkString, RespSimpleString), encode, parseManyWith, parseWith)
import System.X509.Unix (getSystemCertificateStore)

maxRecvBytes :: Int
maxRecvBytes = 4096

main :: IO ()
main = do
  conClient <- connect (NotConnectedPlainTextClient "localhost" (Just (127, 0, 0, 1)))
  print ("Socket connected" :: String)
  send conClient "HELLO 3\r\n"
  parseWith (recieve conClient) >>= print
  send conClient "PING\r\n"
  parseWith (recieve conClient) >>= print
  send conClient (encode (RespArray [RespBulkString "SET", RespBulkString "key", RespBulkString "value"])) >>= print
  parseWith (recieve conClient) >>= print
  send conClient (encode (RespArray [RespBulkString "GET", RespBulkString "key"])) >>= print
  parseWith (recieve conClient) >>= print
  let sendVal = mconcat $ map (\a -> encode (RespArray [RespBulkString "SET", RespBulkString ("key" <> BSC.pack (show a)), RespBulkString "value"])) ([0 .. 100] :: [Integer])
  send conClient sendVal >>= print
  parseManyWith 101 (recieve conClient) >>= print
  let getVal = mconcat $ map (\a -> encode (RespArray [RespBulkString "GET", RespBulkString ("key" <> BSC.pack (show a))])) ([0 .. 100] :: [Integer])
  send conClient getVal >>= print
  parseManyWith 101 (recieve conClient) >>= print
  -- Load system CA certificates
  -- store <- getSystemCertificateStore

  -- let clientParams =
  --       (defaultParamsClient hostname "redis-server")
  --         { clientSupported =
  --             def
  --               { supportedVersions = [TLS13, TLS12],
  --                 supportedCiphers = ciphersuite_strong
  --               },
  --           clientShared =
  --             def
  --               { sharedCAStore = store
  --               }
  --         }
  -- context <- contextNew sock clientParams
  -- handshake context
  -- print "Handshake done"
  -- sendData context "HELLO 3 AUTH default"
  -- parseWith (recvData context) >>= print
  -- sendData context "PING\r\n"
  -- parseWith (recvData context) >>= print
  -- bye context
  close conClient
  return ()
