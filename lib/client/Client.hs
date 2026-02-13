{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | TCP and TLS transport layer for Redis connections.
--
-- The 'Client' typeclass uses a type-level 'ConnectionStatus' parameter to enforce
-- connection state at compile time: you can only 'send' and 'receive' on a
-- @client \'Connected@, and only 'connect' a @client \'NotConnected@. This prevents
-- use-after-close and send-before-connect bugs statically.
module Client
  ( Client (..)
  , serve
  , PlainTextClient (NotConnectedPlainTextClient)
  , TLSClient (NotConnectedTLSClient, NotConnectedTLSClientWithHostname, TLSTunnel)
  , ConnectionStatus (..)
  ) where

import Control.Exception (IOException, bracket, catch, finally, throwIO)
import Control.Monad (void)
import Control.Monad.IO.Class
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Default.Class (def)
import Data.IP (IPv4, toHostAddress)
import Data.Kind (Type)
import Data.Word (Word32)
import Network.DNS
  ( defaultResolvConf,
    lookupA,
    makeResolvSeed,
    withResolver,
  )
import Network.Socket
  ( Family (AF_INET),
    HostAddress,
    SockAddr (SockAddrInet),
    Socket,
    SocketOption (..),
    SocketType (Stream),
    defaultProtocol,
    setSocketOption,
    socket,
    tupleToHostAddress,
  )
import Network.Socket qualified as S
import Network.Socket.ByteString (recv, sendMany)
import Network.Socket.ByteString.Lazy (sendAll)
import Network.TLS (ClientHooks (..), ClientParams (..), Context, Shared (..), Supported (..), Version (..), bye, contextNew, defaultParamsClient, handshake, recvData, sendData)
import Network.TLS.Extra (ciphersuite_strong)
import System.IO (BufferMode (LineBuffering), hFlush, hSetBuffering, stdout)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import System.X509.Unix (getSystemCertificateStore)
import Text.Printf (printf)
import Prelude hiding (getContents)

-- | Connection lifecycle phase, used as a DataKinds-promoted type parameter
-- to statically track whether a client is connected.
data ConnectionStatus = Connected | NotConnected | Server

-- | Transport abstraction indexed by 'ConnectionStatus'. The type parameter
-- ensures that 'send' and 'receive' can only be called on a connected client,
-- and 'connect' can only be called on a not-yet-connected client.
class Client (client :: ConnectionStatus -> Type) where
  connect :: (MonadIO m) => client 'NotConnected -> m (client 'Connected)
  close :: (MonadIO m) => client 'Connected -> m ()
  send :: (MonadIO m) => client 'Connected -> LBS.ByteString -> m ()
  -- | Send multiple strict ByteString chunks via vectored I/O (writev).
  -- Default implementation falls back to 'send' with lazy concatenation.
  -- PlainTextClient overrides with sendMany for zero-copy vectored I/O.
  sendChunks :: (MonadIO m) => client 'Connected -> [BS.ByteString] -> m ()
  sendChunks conn chunks = send conn (LBS.fromChunks chunks)
  receive :: (MonadIO m, MonadFail m) => client 'Connected -> m BS.ByteString

-- | Plain TCP client. Construct with 'NotConnectedPlainTextClient' providing
-- a hostname and optional port (defaults to 6379).
data PlainTextClient (a :: ConnectionStatus) where
  NotConnectedPlainTextClient :: String -> Maybe Int -> PlainTextClient 'NotConnected
  ConnectedPlainTextClient :: String -> Word32 -> Socket -> PlainTextClient 'Connected

instance Client PlainTextClient where
  connect :: (MonadIO m) => PlainTextClient 'NotConnected -> m (PlainTextClient 'Connected)
  connect (NotConnectedPlainTextClient hostname port) = liftIO $ do
    (sock, ipCorrectEndian) <- createSocket hostname (maybe 6379 fromIntegral port)
    S.connect sock (SockAddrInet (maybe 6379 fromIntegral port) ipCorrectEndian) `catch` \(e :: IOException) -> do
      printf "Wasn't able to connect to the server: %s...\n" (show e)
      putStrLn "Tried to use a plain text socket on port 6379. Did you mean to use TLS on port 6380?"
      throwIO e
    return $ ConnectedPlainTextClient hostname ipCorrectEndian sock

  close :: (MonadIO m) => PlainTextClient 'Connected -> m ()
  close (ConnectedPlainTextClient _ _ sock) = liftIO $ S.close sock

  send :: (MonadIO m) => PlainTextClient 'Connected -> LBS.ByteString -> m ()
  send (ConnectedPlainTextClient _ _ sock) dat = liftIO $ sendAll sock dat

  sendChunks :: (MonadIO m) => PlainTextClient 'Connected -> [BS.ByteString] -> m ()
  sendChunks (ConnectedPlainTextClient _ _ sock) chunks = liftIO $ sendMany sock chunks

  receive :: (MonadIO m, MonadFail m) => PlainTextClient 'Connected -> m BS.ByteString
  receive (ConnectedPlainTextClient _ _ sock) = do
    -- Timeout increased to 300s (5 minutes) to handle massive backlogs during fill operations
    val <- liftIO $ timeout (300 * 1000000) $ recv sock 16384
    case val of
      Nothing -> fail "recv socket timeout (plaintext)"
      Just v -> return v

-- | TLS-encrypted client. Construct with 'NotConnectedTLSClient' (hostname + optional port,
-- defaults to 6380) or 'NotConnectedTLSClientWithHostname' when the TLS certificate
-- hostname differs from the connection address (common in cluster mode).
-- Set @REDIS_CLIENT_TLS_INSECURE@ to skip certificate validation.
data TLSClient (a :: ConnectionStatus) where
  NotConnectedTLSClient :: String -> Maybe Int -> TLSClient 'NotConnected
  -- | TLS client with separate hostname for certificate validation
  -- This is useful for cluster mode where CLUSTER SLOTS returns IP addresses
  -- but we need to use the original hostname for TLS certificate validation
  NotConnectedTLSClientWithHostname :: String -> String -> Maybe Int -> TLSClient 'NotConnected
  ConnectedTLSClient :: String -> Word32 -> Socket -> Context -> TLSClient 'Connected
  TLSTunnel :: TLSClient 'Connected -> TLSClient 'Server

instance Client TLSClient where
  connect :: (MonadIO m) => TLSClient 'NotConnected -> m (TLSClient 'Connected)
  connect (NotConnectedTLSClient hostname port) =
    connectTLS hostname hostname port
  
  connect (NotConnectedTLSClientWithHostname certHostname targetAddress port) =
    connectTLS certHostname targetAddress port

  close :: (MonadIO m) => TLSClient 'Connected -> m ()
  close (ConnectedTLSClient _ _ sock ctx) = liftIO $ bye ctx `finally` S.close sock

  send :: (MonadIO m) => TLSClient 'Connected -> LBS.ByteString -> m ()
  send (ConnectedTLSClient _ _ _ ctx) dat = liftIO $ sendData ctx dat

  receive :: (MonadIO m, MonadFail m) => TLSClient 'Connected -> m BS.ByteString
  receive (ConnectedTLSClient _ _ _ ctx) = do
    -- Timeout increased to 300s (5 minutes) to handle massive backlogs
    val <- liftIO $ timeout (300 * 1000000) $ recvData ctx
    case val of
      Nothing -> fail "recv socket timeout (TLS)"
      Just v -> return v

-- | Connect to a TLS server, using certHostname for certificate validation
-- and targetAddress for the actual network connection.
connectTLS :: (MonadIO m) => String -> String -> Maybe Int -> m (TLSClient 'Connected)
connectTLS certHostname targetAddress port = liftIO $ do
  (sock, ipCorrectEndian) <- createSocket targetAddress (maybe 6380 fromIntegral port)
  S.connect sock (SockAddrInet (maybe 6380 fromIntegral port) ipCorrectEndian)
  store <- getSystemCertificateStore
  insecureFlag <- lookupEnv "REDIS_CLIENT_TLS_INSECURE"
  let allowInsecure = maybe False (not . null) insecureFlag
      baseParams =
        (defaultParamsClient certHostname "redis-server")
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
      clientParams =
        if allowInsecure
          then baseParams {clientHooks = def {onServerCertificate = \_ _ _ _ -> pure []}}
          else baseParams
  context <- contextNew sock clientParams
  handshake context
  return $ ConnectedTLSClient certHostname ipCorrectEndian sock context

-- | Start a local TCP proxy on @localhost:6379@ that forwards traffic through an
-- existing TLS connection. Useful for tunneling plain-text Redis tools over TLS.
serve :: (MonadIO m) => TLSClient 'Server -> m ()
serve (TLSTunnel redisClient) = liftIO $ do
  hSetBuffering stdout LineBuffering
  bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
    setSocketOption sock ReuseAddr 1
    S.bind sock (SockAddrInet 6379 (tupleToHostAddress (127, 0, 0, 1)))
    S.listen sock 1024
    putStrLn "Listening on localhost:6379"
    hFlush stdout
    (clientSock, _) <- S.accept sock
    putStrLn "Accepted connection"
    hFlush stdout
    void $
      finally
        (loop clientSock redisClient)
        (S.close clientSock)
  where
    loop client redis = do
      dat <- recv client 4096
      send redisClient (LBS.fromStrict dat)
      receivedData <- receive redis
      sendAll client (LBS.fromStrict receivedData)
      loop client redis

-- | Create a TCP socket with standard options (NoDelay, KeepAlive) and resolve the hostname.
createSocket :: String -> S.PortNumber -> IO (Socket, HostAddress)
createSocket hostname _port = do
  ipAddr <- resolve hostname
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock NoDelay 1
  setSocketOption sock KeepAlive 1
  return (sock, ipAddr)

-- | Resolve a hostname or IP address string to a 'HostAddress'.
-- Handles @\"localhost\"@, dotted-quad IPv4 literals, and DNS A-record lookups.
resolve :: String -> IO HostAddress
resolve "localhost" = return (tupleToHostAddress (127, 0, 0, 1))
resolve address =
  case reads address :: [(IPv4, String)] of
    [(ip, "")] -> return (toHostAddress ip)
    _ -> do
      rs <- makeResolvSeed defaultResolvConf
      result <- withResolver rs $ \resolver -> lookupA resolver (BS8.pack address)
      case result of
        Right (a : _) -> return (toHostAddress a)
        _             -> error $ "no address found for: " ++ address