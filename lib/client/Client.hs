{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Client (Client (..), serve, PlainTextClient (NotConnectedPlainTextClient), TLSClient (NotConnectedTLSClient, TLSTunnel), ClusterClient(..), ConnectionStatus (..), resolve) where

import           Control.Concurrent             (forkIO)
import           Control.Exception              (IOException, bracket, catch,
                                                 finally, throwIO)
import           Control.Monad                  (void)
import           Control.Monad.IO.Class         (MonadIO (..))
import           Crc16                          (crc16)
import           Data.Bits                      (Bits (..))
import qualified Data.ByteString                as B
import qualified Data.ByteString.Char8          as BSC
import           Data.ByteString.Lazy           (fromStrict)
import qualified Data.ByteString.Lazy           as Lazy
import           Data.Default.Class             (def)
import           Data.IP                        (IPv4, fromIPv4w, toHostAddress)
import           Data.Kind                      (Type)
import           Data.Maybe                     (fromMaybe)
import           Data.Word                      (Word32, Word8)
import           Network.DNS                    (DNSError, defaultResolvConf,
                                                 lookupA, makeResolvSeed,
                                                 withResolver)
import           Network.Socket                 (AddrInfo (AddrInfo, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType),
                                                 Family (AF_INET), HostAddress,
                                                 SockAddr (SockAddrInet),
                                                 Socket, SocketOption (..),
                                                 SocketTimeout (SocketTimeout),
                                                 SocketType (Stream),
                                                 defaultProtocol, setSockOpt,
                                                 setSocketOption, socket,
                                                 tupleToHostAddress)
import qualified Network.Socket                 as S
import           Network.Socket.ByteString      (recv)
import           Network.Socket.ByteString.Lazy (sendAll)
import           Network.TLS                    (ClientParams (..), Context,
                                                 Shared (..), Supported (..),
                                                 Version (..), bye, contextNew,
                                                 defaultParamsClient, handshake,
                                                 recvData, sendData)
import           Network.TLS.Extra              (ciphersuite_strong)
import           Prelude                        hiding (getContents)
import           System.Timeout                 (timeout)
import           System.X509.Unix               (getSystemCertificateStore)
import           Text.Printf                    (printf)

data ConnectionStatus = Connected | NotConnected | Server

type Key = String
class Client (client :: ConnectionStatus -> Type) where
  connect :: (MonadIO m) => client 'NotConnected -> m (client 'Connected)
  close :: (MonadIO m) => client 'Connected -> m ()
  send :: (MonadIO m) => client 'Connected -> Key -> Lazy.ByteString -> m () -- Key is needed for cluster mode (hashing keys into their specific slots)
  receive :: (MonadIO m, MonadFail m) => client 'Connected -> Key -> m B.ByteString

data PlainTextClient (a :: ConnectionStatus) where
  NotConnectedPlainTextClient :: String -> Maybe Int -> PlainTextClient 'NotConnected
  ConnectedPlainTextClient :: String -> Word32 -> Socket -> PlainTextClient 'Connected

instance Client PlainTextClient where
  connect :: (MonadIO m) => PlainTextClient 'NotConnected -> m (PlainTextClient 'Connected)
  connect (NotConnectedPlainTextClient hostname port) = liftIO $ do
    ipCorrectEndian <- resolve hostname
    let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = defaultProtocol, addrAddress = SockAddrInet (maybe 6379 fromIntegral port) ipCorrectEndian, addrCanonName = Just hostname}
    sock <- socket (addrFamily addrInfo) (addrSocketType addrInfo) (addrProtocol addrInfo)
    S.connect sock (addrAddress addrInfo) `catch` \(e :: IOException) -> do
      printf "Wasn't able to connect to the server: %s...\n" (show e)
      putStrLn "Tried to use a plain text socket on port 6379. Did you mean to use TLS on port 6380?"
      throwIO e
    return $ ConnectedPlainTextClient hostname ipCorrectEndian sock

  close :: (MonadIO m) => PlainTextClient 'Connected -> m ()
  close (ConnectedPlainTextClient _ _ sock) = liftIO $ S.close sock

  send :: (MonadIO m) => PlainTextClient 'Connected -> Key -> Lazy.ByteString -> m ()
  send (ConnectedPlainTextClient _ _ sock) _ dat = liftIO $ sendAll sock dat

  receive :: (MonadIO m, MonadFail m) => PlainTextClient 'Connected -> Key -> m B.ByteString
  receive (ConnectedPlainTextClient _ _ sock) _ = do
    val <- liftIO $ timeout (5 * 1000000) $ recv sock 4096
    case val of
      Nothing -> fail "recv socket timeout"
      Just v  -> return v

data TLSClient (a :: ConnectionStatus) where
  NotConnectedTLSClient :: String -> Maybe Int -> TLSClient 'NotConnected
  ConnectedTLSClient :: String -> Word32 -> Socket -> Context -> TLSClient 'Connected
  TLSTunnel :: TLSClient 'Connected -> TLSClient 'Server

instance Client TLSClient where
  connect :: (MonadIO m) => TLSClient 'NotConnected -> m (TLSClient 'Connected)
  connect (NotConnectedTLSClient hostname port) = liftIO $ do
    ipCorrectEndian <- resolve hostname
    let addrInfo = AddrInfo {addrFlags = [], addrFamily = AF_INET, addrSocketType = Stream, addrProtocol = defaultProtocol, addrAddress = SockAddrInet (maybe 6380 fromIntegral port) ipCorrectEndian, addrCanonName = Just hostname}
    sock <- socket (addrFamily addrInfo) (addrSocketType addrInfo) (addrProtocol addrInfo)
    S.connect sock (addrAddress addrInfo)
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
    return $ ConnectedTLSClient hostname ipCorrectEndian sock context

  close :: (MonadIO m) => TLSClient 'Connected -> m ()
  close (ConnectedTLSClient _ _ sock ctx) = liftIO $ bye ctx `finally` S.close sock

  send :: (MonadIO m) => TLSClient 'Connected -> Key -> Lazy.ByteString -> m ()
  send (ConnectedTLSClient _ _ _ ctx) _ dat = liftIO $ sendData ctx dat

  receive :: (MonadIO m, MonadFail m) => TLSClient 'Connected -> Key -> m B.ByteString
  receive (ConnectedTLSClient _ _ _ ctx) _ = do
    val <- liftIO $ timeout (5 * 1000000) $ recvData ctx
    case val of
      Nothing -> fail "recv socket timeout"
      Just v  -> return v

serve :: (MonadIO m) => TLSClient 'Server -> m ()
serve (TLSTunnel redisClient) = liftIO $ do
  bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
    setSocketOption sock ReuseAddr 1
    S.bind sock (SockAddrInet 6379 (tupleToHostAddress (127, 0, 0, 1)))
    S.listen sock 1024
    putStrLn "Listening on localhost:6379"
    (clientSock, _) <- S.accept sock
    putStrLn "Accepted connection"
    void $
      finally
        (loop clientSock redisClient)
        (S.close clientSock)
  where
    loop client redis = do
      dat <- recv client 4096
      send redisClient mempty (fromStrict dat)
      recieveData <- receive redis mempty
      sendAll client (fromStrict recieveData)
      loop client redis

data ClusterClient (connected :: ConnectionStatus) where
  NotConnectedClusterClient :: (Client client) => [client 'NotConnected] -> ClusterClient  'NotConnected
  ConnectedClusterClient :: (Client client) => (Key -> client 'Connected) -> [client 'Connected] -> ClusterClient  'Connected

instance Client ClusterClient where
  connect :: MonadIO m => ClusterClient NotConnected -> m (ClusterClient  Connected)
  connect  (NotConnectedClusterClient clients) = do
    connectedClients <- mapM connect clients
    let connected = ConnectedClusterClient (\_ -> undefined) connectedClients -- Placeholder for actual socket creation
    return connected
  close :: MonadIO m => ClusterClient  Connected -> m ()
  close (ConnectedClusterClient _ clients) = do
    mapM_ close clients
  send :: MonadIO m => ClusterClient  Connected -> Key -> Lazy.ByteString -> m ()
  send (ConnectedClusterClient mapFunc clients) key dat = do
    let clientsToSend = if key == mempty
                    then   clients
                    else   [mapFunc key]
    mapM_ (\c -> send c key dat ) clientsToSend -- Basically, if there's no key then just send the command to everybody
  receive :: (MonadIO m, MonadFail m) => ClusterClient  Connected -> Key -> m BSC.ByteString
  receive (ConnectedClusterClient mapFunc clients) key = do
    let clientsToReceive = if key == mempty
                    then   clients
                    else   [mapFunc key]
    head <$> mapM (`receive` mempty) clientsToReceive -- Only care about the first response in the case of cluster commands that get spewed this is a dummy implemntation until something more complete can be decided upon
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
resolve "localhost" = return (tupleToHostAddress (127, 0, 0, 1))
resolve address = do
  rs <- makeResolvSeed defaultResolvConf
  addrInfo <- withResolver rs $ \resolver -> do
    lookupA resolver (BSC.pack address)
  return $ f addrInfo
  where
    f :: Either DNSError [IPv4] -> HostAddress
    f (Right (a : _)) = toHostAddress a
    f _               = error "no address found"

byteStringToString :: B.ByteString -> String
byteStringToString = map (toEnum . fromEnum) . B.unpack
