{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Bits (Bits ((.|.)), shiftL, shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Default.Class (def)
import Data.IP (IPv4, fromIPv4w)
import Data.Word (Word32)
import Network.DNS
import Network.Socket
import Network.TLS
import Network.TLS.Extra.Cipher
import System.X509.Unix (getSystemCertificateStore)

main :: IO ()
main = do
  let hostname = "sspeaks-eus2euap-test.redis.cache.windows.net"
  ip <- resolve hostname
  let ipCorrectEndian = toNetworkByteOrder ip
  print $ hostAddressToTuple ipCorrectEndian
  let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = 0, addrAddress = SockAddrInet 6380 ipCorrectEndian, addrCanonName = Just hostname}
  sock <- openSocket addrInfo
  connect sock (addrAddress addrInfo)
  print "Socket connected"

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
  print "Handshake done"
  sendData context "HELLO 3 AUTH default <password>\r\n"
  recvData context >>= print
  sendData context "PING\r\n"
  recvData context >>= print
  bye context
  close sock
  return ()

toNetworkByteOrder :: Word32 -> Word32
toNetworkByteOrder hostOrder =
  (hostOrder `shiftR` 24) .&. 0xFF
    .|. (hostOrder `shiftR` 8) .&. 0xFF00
    .|. (hostOrder `shiftL` 8) .&. 0xFF0000
    .|. (hostOrder `shiftL` 24) .&. 0xFF000000

resolve :: String -> IO HostAddress
resolve address = do
  rs <- makeResolvSeed defaultResolvConf
  addrInfo <- withResolver rs $ \resolver -> do
    lookupA resolver (BSC.pack address)
  return $ f addrInfo
  where
    f :: Either DNSError [IPv4] -> HostAddress
    f (Right (a : _)) = fromIPv4w a
    f _ = error "no address found"

byteStringToString :: BS.ByteString -> String
byteStringToString = map (toEnum . fromEnum) . BS.unpack