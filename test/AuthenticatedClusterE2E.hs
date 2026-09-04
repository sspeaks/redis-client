{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent     (threadDelay)
import           Control.Concurrent.STM (readTVarIO)
import           Control.Exception      (SomeException, bracket, try)
import           Control.Monad.IO.Class (liftIO)
import qualified Control.Monad.State    as State
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import qualified Data.ByteString.Lazy   as LBS
import           Data.IORef             (IORef, atomicModifyIORef', newIORef,
                                         readIORef)
import qualified Data.Map.Strict        as Map
import           Database.Redis
import           Database.Redis.Cluster (calculateSlot, findNodeAddressForSlot)
import           Test.Hspec

defaultPassword :: ByteString
defaultPassword = "redis-client-e2e-password"

aclUsername :: ByteString
aclUsername = "redis-client-e2e-acl"

aclPassword :: ByteString
aclPassword = "redis-client-e2e-acl-password"

seedNode :: NodeAddress
seedNode = NodeAddress "redis-auth1.local" 6379

testClusterConfig :: ClusterConfig
testClusterConfig = ClusterConfig
  { clusterSeedNode = seedNode
  , clusterPoolConfig = PoolConfig
      { maxConnectionsPerNode = 2
      , connectionTimeout = 10
      , maxRetries = 3
      , useTLS = False
      }
  , clusterMaxRetries = 5
  , clusterRetryDelay = 100000
  , clusterTopologyRefreshInterval = 600
  }

main :: IO ()
main = hspec $ describe "authenticated Redis Cluster interoperability" $ do
  it "requires authentication before topology discovery" $ do
    result <- try $ createClusterClient testClusterConfig clusterPlaintextConnector
      :: IO (Either SomeException (ClusterClient PlainTextClient))
    case result of
      Left _ -> return ()
      Right client -> do
        closeClusterClient client
        expectationFailure "Unauthenticated topology discovery succeeded"

  it "uses password authentication across masters and after replacement" $ do
    counts <- newIORef Map.empty
    let connector = trackingConnector counts
    bracket
      (createClusterClientWithAuthentication
        testClusterConfig (ClusterPassword defaultPassword) connector)
      closeClusterClient $ \client -> do
        (firstAddress, firstKey, secondAddress, secondKey) <-
          keysOnTwoMasters client

        runClusterCommandClient client (set firstKey "password-first")
          `shouldReturn` RespSimpleString "OK"
        runClusterCommandClient client (set secondKey "password-second")
          `shouldReturn` RespSimpleString "OK"
        runClusterCommandClient client (get firstKey)
          `shouldReturn` RespBulkString "password-first"
        runClusterCommandClient client ping
          `shouldReturn` RespSimpleString "PONG"
        firstConnections <- connectionCount counts firstAddress
        secondConnections <- connectionCount counts secondAddress
        firstConnections `shouldSatisfy` (> 0)
        secondConnections `shouldSatisfy` (> 0)
        refreshTopology client

        replacementAddress <-
          if firstAddress /= seedNode
            then return firstAddress
            else if secondAddress /= seedNode
              then return secondAddress
              else expectationFailure "Expected a non-seed master"
                >> return firstAddress
        replacementKey <-
          if replacementAddress == firstAddress
            then return firstKey
            else return secondKey

        connectionsBefore <- connectionCount counts replacementAddress
        killed <- killNormalClients
          (ClusterPassword defaultPassword) replacementAddress
        killed `shouldSatisfy` (> 0)
        threadDelay 250000

        runClusterCommandClient client (get replacementKey)
          `shouldReturn`
            if replacementKey == firstKey
              then RespBulkString "password-first"
              else RespBulkString "password-second"
        connectionsAfter <- connectionCount counts replacementAddress
        connectionsAfter `shouldSatisfy` (> connectionsBefore)

  it "uses ACL authentication while retaining RESP2 on separate masters" $ do
    counts <- newIORef Map.empty
    bracket
      (createClusterClientWithAuthentication testClusterConfig
        (ClusterACL aclUsername aclPassword) (trackingConnector counts))
      closeClusterClient $ \client -> do
        (_, firstKey, _, secondKey) <- keysOnTwoMasters client

        slots <- runClusterCommandClient client clusterSlots
        slots `shouldSatisfy` \case
          RespArray ranges -> not $ null ranges
          _                -> False

        runClusterCommandClient client (set firstKey "acl-first")
          `shouldReturn` RespSimpleString "OK"
        runClusterCommandClient client (set secondKey "acl-second")
          `shouldReturn` RespSimpleString "OK"
        runClusterCommandClient client (get firstKey)
          `shouldReturn` RespBulkString "acl-first"
        runClusterCommandClient client (get secondKey)
          `shouldReturn` RespBulkString "acl-second"

trackingConnector
  :: IORef (Map.Map NodeAddress Int)
  -> Connector PlainTextClient
trackingConnector counts address = do
  atomicModifyIORef' counts $ \current ->
    (Map.insertWith (+) address 1 current, ())
  clusterPlaintextConnector address

connectionCount
  :: IORef (Map.Map NodeAddress Int)
  -> NodeAddress
  -> IO Int
connectionCount counts address =
  Map.findWithDefault 0 address <$> readIORef counts

keysOnTwoMasters
  :: ClusterClient PlainTextClient
  -> IO (NodeAddress, ByteString, NodeAddress, ByteString)
keysOnTwoMasters client = do
  topology <- readTVarIO $ clusterTopology client
  let masters =
        [ nodeAddress node
        | node <- Map.elems $ topologyNodes topology
        , nodeRole node == Master
        ]
  case masters of
    firstAddress : secondAddress : _ -> do
      firstKey <- keyForAddress topology firstAddress
      secondKey <- keyForAddress topology secondAddress
      return (firstAddress, firstKey, secondAddress, secondKey)
    _ -> expectationFailure "Expected at least two cluster masters"
      >> return (seedNode, "missing-first", seedNode, "missing-second")

keyForAddress :: ClusterTopology -> NodeAddress -> IO ByteString
keyForAddress topology expected = findKey (0 :: Int)
  where
    findKey index
      | index > 100000 =
          expectationFailure ("Could not find key for " ++ show expected)
            >> return "missing-key"
      | findNodeAddressForSlot topology (calculateSlot candidate)
          == Just expected =
          return candidate
      | otherwise = findKey $ index + 1
      where
        candidate = BS8.pack $ "authenticated-e2e-key-" ++ show index

killNormalClients
  :: ClusterAuthentication
  -> NodeAddress
  -> IO Integer
killNormalClients authentication address =
  bracket (clusterPlaintextConnector address) close $ \admin -> do
    authResponse <- runDirect admin $ case authentication of
      ClusterPassword password     -> auth "default" password
      ClusterACL username password -> auth username password
    authResponse `shouldSatisfy` \case
      RespSimpleString "OK" -> True
      RespArray _           -> True
      _                     -> False

    response <- runRaw admin ["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"]
    case response of
      RespInteger killed -> return killed
      other -> expectationFailure
        ("Unexpected CLIENT KILL response: " ++ show other) >> return 0

runDirect
  :: PlainTextClient 'Connected
  -> RedisCommandClient PlainTextClient a
  -> IO a
runDirect client command =
  State.evalStateT
    (runRedisCommandClient command)
    (ClientState client BS.empty)

runRaw
  :: PlainTextClient 'Connected
  -> [ByteString]
  -> IO RespData
runRaw client arguments = runDirect client $ RedisCommandClient $ do
  ClientState connected _ <- State.get
  liftIO $ send connected $
    LBS.fromStrict $ encodeCommand arguments
  parseWith $ liftIO $ receive connected
