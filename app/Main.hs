{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Network.Socket
import Network.TLS
import Network.TLS.Extra.Cipher
import System.X509.Unix (getSystemCertificateStore)

main :: IO ()
main = do
  let ip = tupleToHostAddress (9, 223, 65, 55) -- "9.223.65.55"
  let hostname = "sspeaks-swec-test-02-18-25.cache.icbbvt.windows-int.net"
  let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = 0, addrAddress = SockAddrInet 6380 ip, addrCanonName = Just hostname}
  sock <- openSocket addrInfo
  connect sock (addrAddress addrInfo)

  -- Load system CA certificates
  store <- getSystemCertificateStore

  let clientParams =
        (defaultParamsClient hostname "redis-server")
          { clientSupported =
              def
                { supportedVersions = [TLS13, TLS12],
                  supportedCiphers = ciphersuite_strong
                },
            clientShared =
              def
                { sharedCAStore = store
                }
          }
  context <- contextNew sock clientParams
  handshake context
  sendData context "HELLO 3 AUTH default <password>\r\n"
  recvData context >>= print
  sendData context "PING\r\n"
  recvData context >>= print
  bye context
  close sock
  return ()

byteStringToString :: BS.ByteString -> String
byteStringToString = map (toEnum . fromEnum) . BS.unpack