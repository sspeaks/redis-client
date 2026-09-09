{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           AppConfig                     (RunState (..), defaultRunState)
import           ClusterSetup                  (createClusterClientFromState)
import           Control.Concurrent            (threadDelay)
import           Control.Monad.IO.Class        (liftIO)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Builder       as Builder
import qualified Data.ByteString.Lazy          as LBS
import           Data.IORef                    (IORef, atomicModifyIORef',
                                                newIORef, readIORef)
import           Database.Redis.Client         (Client (..),
                                                ConnectionStatus (..))
import           Database.Redis.Cluster        (NodeAddress (..))
import           Database.Redis.Cluster.Client (closeClusterClient)
import           Database.Redis.Command        (encodeCommandBuilder)
import           Database.Redis.Resp           (Encodable (encode),
                                                RespData (..))
import           Test.Hspec

data SetupClient (status :: ConnectionStatus) where
  SetupConnected
    :: !(IORef ByteString)
    -> !(IORef [ByteString])
    -> SetupClient 'Connected

instance Client SetupClient where
  connect = error "SetupClient: connect not supported"
  close _ = return ()
  send (SetupConnected sent _) lbs =
    liftIO $ atomicModifyIORef' sent $ \old ->
      (old <> LBS.toStrict lbs, ())
  receive (SetupConnected _ responses) =
    liftIO $ receiveNext responses

receiveNext :: IORef [ByteString] -> IO ByteString
receiveNext responses = do
  next <- atomicModifyIORef' responses $ \case
    []       -> ([], Nothing)
    (x : xs) -> (xs, Just x)
  case next of
    Just response -> return response
    Nothing       -> threadDelay 1000 >> receiveNext responses

main :: IO ()
main = hspec $ describe "cluster executable setup" $ do
  it "maps the default user to password AUTH before topology discovery" $ do
    (connector, sent) <- setupConnector
      [ RespSimpleString "OK", validClusterSlots ]
    client <- createClusterClientFromState
      (credentialState "default" "password-secret")
      connector
    readIORef sent `shouldReturn`
      commandBytes ["AUTH", "password-secret"]
        <> commandBytes ["CLUSTER", "SLOTS"]
    closeClusterClient client

  it "maps a named ACL user to HELLO 2 AUTH before topology discovery" $ do
    (connector, sent) <- setupConnector
      [ RespArray [RespBulkString "proto", RespInteger 2]
      , validClusterSlots
      ]
    client <- createClusterClientFromState
      (credentialState "acl-user" "acl-secret")
      connector
    readIORef sent `shouldReturn`
      commandBytes ["HELLO", "2", "AUTH", "acl-user", "acl-secret"]
        <> commandBytes ["CLUSTER", "SLOTS"]
    closeClusterClient client

  it "keeps unauthenticated cluster construction compatible" $ do
    (connector, sent) <- setupConnector [validClusterSlots]
    client <- createClusterClientFromState
      (defaultRunState
        { host = "127.0.0.1"
        , port = Just 6379
        })
      connector
    readIORef sent `shouldReturn` commandBytes ["CLUSTER", "SLOTS"]
    closeClusterClient client

setupConnector
  :: [RespData]
  -> IO
      ( NodeAddress -> IO (SetupClient 'Connected)
      , IORef ByteString
      )
setupConnector responses = do
  sent <- newIORef BS.empty
  encodedResponses <- newIORef $ map encodeResp responses
  return (const $ return $ SetupConnected sent encodedResponses, sent)

credentialState :: String -> String -> RunState
credentialState authUsername authPassword = defaultRunState
  { host = "127.0.0.1"
  , port = Just 6379
  , username = authUsername
  , password = authPassword
  , allowInsecurePlaintextAuth = True
  }

validClusterSlots :: RespData
validClusterSlots =
  RespArray
    [ RespArray
        [ RespInteger 0
        , RespInteger 16383
        , RespArray
            [ RespBulkString "127.0.0.1"
            , RespInteger 6379
            , RespBulkString "test-node-id"
            ]
        ]
    ]

encodeResp :: RespData -> ByteString
encodeResp =
  LBS.toStrict . Builder.toLazyByteString . encode

commandBytes :: [ByteString] -> ByteString
commandBytes =
  LBS.toStrict . Builder.toLazyByteString . encodeCommandBuilder
