{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module AppConfig
  ( RunState (..)
  , defaultRunState
  , resolveRunStateCredentials
  , plaintextAuthenticationPolicy
  , enforcePlaintextAuthenticationPolicy
  , warnIfInsecurePlaintextAuthentication
  , authenticate
  , runCommandsAgainstTLSHost
  , runCommandsAgainstPlaintextHost
  ) where

import           Control.Exception        (bracket, onException)
import qualified Control.Monad.State      as State
import           CredentialConfig         (resolveRedisPassword)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BS8
import           Data.Maybe               (fromMaybe)
import           Database.Redis.Client    (Client (..), ConnectionPhase (..),
                                           ConnectionStatus (..),
                                           PlainTextClient, TLSClient,
                                           connectPlaintextWithCleanup,
                                           connectTLSWithCleanup)
import           Database.Redis.Cluster   (NodeAddress (..))
import           Database.Redis.Command   (ClientState (..),
                                           RedisCommandClient (..),
                                           RedisCommands (..))
import           Database.Redis.Connector (ConnectionSupervisor (..),
                                           withConnectionTimeoutSupervised)
import           Database.Redis.Resp      (RespData (..))
import           System.IO                (hPutStrLn, stderr)

data RunState = RunState
  { host                       :: String,
    port                       :: Maybe Int,
    username                   :: String,
    password                   :: String,
    useTLS                     :: Bool,
    allowInsecurePlaintextAuth :: Bool,
    dataGBs                    :: Int,
    flush                      :: Bool,
    serial                     :: Bool,
    numConnections             :: Maybe Int,
    useCluster                 :: Bool,
    tunnelMode                 :: String,
    keySize                    :: Int,
    valueSize                  :: Int,
    pipelineBatchSize          :: Int,
    numProcesses               :: Maybe Int,
    processIndex               :: Maybe Int,
    benchOperation             :: String,
    benchDuration              :: Int,
    muxCount                   :: Int
  }

defaultRunState :: RunState
defaultRunState = RunState
  { host = ""
  , port = Nothing
  , username = "default"
  , password = ""
  , useTLS = False
  , allowInsecurePlaintextAuth = False
  , dataGBs = 0
  , flush = False
  , serial = False
  , numConnections = Just 2
  , useCluster = False
  , tunnelMode = "smart"
  , keySize = 512
  , valueSize = 512
  , pipelineBatchSize = 8192
  , numProcesses = Nothing
  , processIndex = Nothing
  , benchOperation = "set"
  , benchDuration = 30
  , muxCount = 1
  }

resolveRunStateCredentials :: RunState -> IO RunState
resolveRunStateCredentials state = do
  resolvedPassword <- resolveRedisPassword
  pure state {password = resolvedPassword}

plaintextAuthenticationPolicy :: RunState -> Either String (Maybe String)
plaintextAuthenticationPolicy state
  | null (password state) || useTLS state = Right Nothing
  | not (allowInsecurePlaintextAuth state) =
      Left "Refusing to send Redis credentials over plaintext. Enable TLS with --tls, or explicitly acknowledge the risk with --allow-insecure-plaintext-auth."
  | otherwise =
      Right . Just $
        "WARNING: INSECURE PLAINTEXT AUTHENTICATION ENABLED for "
          ++ show (host state)
          ++ ". Redis credentials will be sent unencrypted."

enforcePlaintextAuthenticationPolicy :: RunState -> IO ()
enforcePlaintextAuthenticationPolicy state =
  case plaintextAuthenticationPolicy state of
    Left message -> ioError $ userError message
    Right _      -> pure ()

warnIfInsecurePlaintextAuthentication :: RunState -> IO ()
warnIfInsecurePlaintextAuthentication state =
  case plaintextAuthenticationPolicy state of
    Left message         -> ioError $ userError message
    Right Nothing        -> pure ()
    Right (Just warning) -> hPutStrLn stderr warning

authenticate :: (Client client) => String -> String -> RedisCommandClient client RespData
authenticate _ [] = return $ RespSimpleString "OK"
authenticate uname pwd = do
  (_ :: RespData) <- auth (BS8.pack uname) (BS8.pack pwd)
  (_ :: RespData) <- clientSetInfo ["LIB-NAME", "hask-redis-mux"]
  clientSetInfo ["LIB-VER", "0.0.0"]

runCommandsAgainstTLSHost :: RunState -> RedisCommandClient TLSClient a -> IO a
runCommandsAgainstTLSHost st action = do
  bracket (connectTLSHost st) close $ \client -> do
    State.evalStateT
      (runRedisCommandClient action)
      (ClientState client BS.empty)

runCommandsAgainstPlaintextHost :: RunState -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHost st action = do
  enforcePlaintextAuthenticationPolicy st
  bracket (connectPlaintextHost st) close
    $ \client -> State.evalStateT
        (runRedisCommandClient action)
        (ClientState client BS.empty)

connectTLSHost :: RunState -> IO (TLSClient 'Connected)
connectTLSHost st =
  withConnectionTimeoutSupervised 300 DNSResolution
    (\supervisor _ -> do
      client <- connectTLSWithCleanup
        (setConnectionPhase supervisor)
        (registerSetupCleanup supervisor)
        (host st)
        (host st)
        (port st)
      authenticateConnected st supervisor client)
    endpoint
  where
    endpoint = NodeAddress (host st) $ fromMaybe 6380 (port st)

connectPlaintextHost :: RunState -> IO (PlainTextClient 'Connected)
connectPlaintextHost st =
  withConnectionTimeoutSupervised 300 DNSResolution
    (\supervisor _ -> do
      client <- connectPlaintextWithCleanup
        (setConnectionPhase supervisor)
        (registerSetupCleanup supervisor)
        (host st)
        (port st)
      authenticateConnected st supervisor client)
    endpoint
  where
    endpoint = NodeAddress (host st) $ fromMaybe 6379 (port st)

authenticateConnected
  :: (Client client)
  => RunState
  -> ConnectionSupervisor client
  -> client 'Connected
  -> IO (client 'Connected)
authenticateConnected st supervisor client = do
  cleanup <- registerConnectedTransport supervisor client
  setConnectionPhase supervisor Authentication
  (do
      _ <- State.evalStateT
        (runRedisCommandClient $
          authenticate (username st) (password st))
        (ClientState client BS.empty)
      return client)
    `onException` cleanup
