{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Client (Client (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (NotConnectedTLSClient), ConnectionStatus (..)) where

import Control.Monad (void)
import Control.Monad.IO.Class
import Data.Bits (Bits (..))
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy (fromStrict)
import Data.ByteString.Lazy qualified as Lazy
import Data.Default.Class (def)
import Data.IP (IPv4, fromIPv4w)
import Data.Kind (Type)
import Data.Word (Word32, Word8)
import Network.DNS
  ( DNSError,
    defaultResolvConf,
    lookupA,
    makeResolvSeed,
    withResolver,
  )
import Network.Socket
  ( AddrInfo
      ( AddrInfo,
        addrAddress,
        addrCanonName,
        addrFamily,
        addrFlags,
        addrProtocol,
        addrSocketType
      ),
    Family (AF_INET),
    HostAddress,
    SockAddr (SockAddrInet),
    Socket,
    SocketType (Stream),
    openSocket,
    tupleToHostAddress,
  )
import Network.Socket qualified as S
import Network.Socket.ByteString (recv)
import Network.Socket.ByteString.Lazy (sendAll)
import Network.TLS (ClientParams (..), Context, Shared (..), Supported (..), Version (..), bye, contextNew, defaultParamsClient, handshake, recvData, sendData)
import Network.TLS.Extra (ciphersuite_strong)
import System.X509.Unix (getSystemCertificateStore)
import Prelude hiding (getContents)

data ConnectionStatus = Connected | NotConnected

class Client (client :: ConnectionStatus -> Type) where
  connect :: (MonadIO m) => client 'NotConnected -> m (client 'Connected)
  close :: (MonadIO m) => client 'Connected -> m ()
  send :: (MonadIO m) => client 'Connected -> Lazy.ByteString -> m ()
  recieve :: (MonadIO m) => client 'Connected -> m B.ByteString

data PlainTextClient (a :: ConnectionStatus) where
  NotConnectedPlainTextClient :: String -> Maybe (Word8, Word8, Word8, Word8) -> PlainTextClient 'NotConnected
  ConnectedPlainTextClient :: String -> Word32 -> Socket -> PlainTextClient 'Connected

instance Client PlainTextClient where
  connect :: (MonadIO m) => PlainTextClient 'NotConnected -> m (PlainTextClient 'Connected)
  connect (NotConnectedPlainTextClient hostname maybeTuple) = do
    ipCorrectEndian <- case maybeTuple of
      Nothing -> toNetworkByteOrder <$> liftIO (resolve hostname)
      (Just tup) -> pure $ tupleToHostAddress tup
    let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = 0, addrAddress = SockAddrInet 6379 ipCorrectEndian, addrCanonName = Just hostname}
    sock <- liftIO $ openSocket addrInfo
    liftIO $ S.connect sock (addrAddress addrInfo)
    return $ ConnectedPlainTextClient hostname ipCorrectEndian sock
  close :: (MonadIO m) => PlainTextClient 'Connected -> m ()
  close (ConnectedPlainTextClient _ _ sock) = liftIO $ S.close sock
  send :: (MonadIO m) => PlainTextClient 'Connected -> Lazy.ByteString -> m ()
  send (ConnectedPlainTextClient _ _ sock) dat = liftIO $ sendAll sock dat
  recieve :: (MonadIO m) => PlainTextClient 'Connected -> m B.ByteString
  recieve (ConnectedPlainTextClient _ _ sock) = liftIO $ recv sock 4096

data TLSClient (a :: ConnectionStatus) where
  NotConnectedTLSClient :: String -> Maybe (Word8, Word8, Word8, Word8) -> TLSClient 'NotConnected
  ConnectedTLSClient :: String -> Word32 -> Socket -> Context -> TLSClient 'Connected

instance Client TLSClient where
  connect :: (MonadIO m) => TLSClient 'NotConnected -> m (TLSClient 'Connected)
  connect (NotConnectedTLSClient hostname maybeTuple) = do
    ipCorrectEndian <- case maybeTuple of
      Nothing -> toNetworkByteOrder <$> liftIO (resolve hostname)
      (Just tup) -> pure $ tupleToHostAddress tup
    let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = 0, addrAddress = SockAddrInet 6380 ipCorrectEndian, addrCanonName = Just hostname}
    sock <- liftIO $ openSocket addrInfo
    liftIO $ S.connect sock (addrAddress addrInfo)
    -- Load system CA certificates
    store <- liftIO getSystemCertificateStore

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
    return $ ConnectedTLSClient hostname ipCorrectEndian sock context
  close :: (MonadIO m) => TLSClient 'Connected -> m ()
  close (ConnectedTLSClient _ _ sock ctx) = liftIO $ bye ctx >> S.close sock
  send :: (MonadIO m) => TLSClient 'Connected -> Lazy.ByteString -> m ()
  send (ConnectedTLSClient _ _ _ ctx) dat = liftIO $ sendData ctx dat
  recieve :: (MonadIO m) => TLSClient 'Connected -> m B.ByteString
  recieve (ConnectedTLSClient _ _ _ ctx) = liftIO $ recvData ctx

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