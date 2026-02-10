{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module AppConfig
  ( RunState (..)
  , defaultRunState
  , authenticate
  , runCommandsAgainstTLSHost
  , runCommandsAgainstPlaintextHost
  ) where

import Client (Client (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (..))
import Control.Exception (bracket)
import qualified Control.Monad.State as State
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import RedisCommandClient (ClientState (..), RedisCommandClient (..), RedisCommands (..))
import Resp (RespData (..))

data RunState = RunState
  { host :: String,
    port :: Maybe Int,
    username :: String,
    password :: String,
    useTLS :: Bool,
    dataGBs :: Int,
    flush :: Bool,
    serial :: Bool,
    numConnections :: Maybe Int,
    useCluster :: Bool,
    tunnelMode :: String,
    keySize :: Int,
    valueSize :: Int,
    pipelineBatchSize :: Int,
    numProcesses :: Maybe Int,
    processIndex :: Maybe Int
  }
  deriving (Show)

defaultRunState :: RunState
defaultRunState = RunState
  { host = ""
  , port = Nothing
  , username = "default"
  , password = ""
  , useTLS = False
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
  }

authenticate :: (Client client) => String -> String -> RedisCommandClient client RespData
authenticate _ [] = return $ RespSimpleString "OK"
authenticate uname pwd = do
  _ <- auth (BS8.pack uname) (BS8.pack pwd)
  _ <- clientSetInfo ["LIB-NAME", "seth-spaghetti"]
  clientSetInfo ["LIB-VER", "0.0.0"]

runCommandsAgainstTLSHost :: RunState -> RedisCommandClient TLSClient a -> IO a
runCommandsAgainstTLSHost st action = do
  bracket (connect (NotConnectedTLSClient (host st) (port st))) close $ \client -> do
    State.evalStateT (runRedisCommandClient (authenticate (username st) (password st) >> action)) (ClientState client BS.empty)

runCommandsAgainstPlaintextHost :: RunState -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHost st action =
  bracket
    (connect $ NotConnectedPlainTextClient (host st) (port st))
    close
    $ \client -> State.evalStateT (runRedisCommandClient (authenticate (username st) (password st) >> action)) (ClientState client BS.empty)
