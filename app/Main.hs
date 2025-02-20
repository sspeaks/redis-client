{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Bits (Bits ((.|.)), shiftL, shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Default.Class (def)
import Data.IP (IPv4, fromIPv4w)
import Data.Word (Word32)
import Network.DNS
  ( DNSError,
    defaultResolvConf,
    lookupA,
    makeResolvSeed,
    withResolver,
  )
import Network.Socket
import Network.Socket.ByteString.Lazy (getContents, sendAll)
import Network.TLS
import Network.TLS.Extra.Cipher
import Resp (RespData (RespArray, RespSimpleString, RespBulkString), encode, parseWith)
import System.X509.Unix (getSystemCertificateStore)
import Prelude hiding (getContents)

maxRecvBytes :: Int
maxRecvBytes = 4096

main :: IO ()
main = do
  
  connect sock (addrAddress addrInfo)
  print "Socket connected"
  sendAll sock "HELLO 3\r\n"
  parseWith (getContents sock) >>= print
  sendAll sock "PING\r\n"
  parseWith (getContents sock) >>= print
  sendAll sock (encode (RespArray [RespBulkString "SET", RespBulkString "key", RespBulkString "value"])) >>= print
  parseWith (getContents sock) >>= print
  sendAll sock (encode (RespArray [RespBulkString "GET", RespBulkString "key"])) >>= print
  parseWith (getContents sock) >>= print
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
  close sock
  return ()

