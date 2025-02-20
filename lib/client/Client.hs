module Client (Client, PlainTextClient, defaultPlainTextClient) where

import qualified Data.ByteString as B
import Data.Word (Word8, Word32)
import Control.Monad.IO.Class
import Network.Socket
import Network.DNS
import Data.IP (IPv4, fromIPv4w)
import Data.Bits (Bits(..))
import qualified Data.ByteString.Char8 as BSC

class Client client where
    connect :: MonadIO m => client -> m client
    close :: (MonadIO m) => client -> m ()
    send :: (MonadIO m) => client -> B.ByteString -> m Bool
    recieve :: (MonadIO m) => client -> m (Either String B.ByteString)

data PlainTextClient = PlainTextClient {
    hostName :: String,
    ipTuple :: Maybe (Word8, Word8, Word8, Word8),
    sock :: Maybe Socket
}

instance Client PlainTextClient where
  connect :: MonadIO m => PlainTextClient -> m PlainTextClient
  connect client = do
    let hostname = hostName client
    -- ip <- resolve hostname
    ipCorrectEndian <- case ipTuple client of
                                  Nothing -> toNetworkByteOrder <$> liftIO (resolve hostname)
                                  (Just tup) -> pure $ tupleToHostAddress tup
    let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = 0, addrAddress = SockAddrInet 6379 ipCorrectEndian, addrCanonName = Just hostname}
    sock <- liftIO $ openSocket addrInfo
    return $ client {
      sock = Just sock
    }
  close :: MonadIO m => PlainTextClient -> m ()
  close = _
  send = _
  recieve = _



defaultPlainTextClient :: PlainTextClient
defaultPlainTextClient = PlainTextClient "localhost" Nothing Nothing

toNetworkByteOrder :: Word32 -> Word32
toNetworkByteOrder hostOrder =
  (hostOrder `shiftR` 24)
    .&. 0xFF
    .|. (hostOrder `shiftR` 8)
    .&. 0xFF00
    .|. (hostOrder `shiftL` 8)
    .&. 0xFF0000
    .|. (hostOrder `shiftL` 24)
    .&. 0xFF000000

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

byteStringToString :: B.ByteString -> String
byteStringToString = map (toEnum . fromEnum) . B.unpack