{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent                    (threadDelay)
import           Control.Concurrent.Async              (mapConcurrently)
import           Control.Concurrent.STM                (readTVarIO)
import           Control.Exception                     (SomeException, bracket,
                                                        bracketOnError, try)
import           Control.Monad                         (forM_)
import           Control.Monad.IO.Class                (liftIO)
import qualified Control.Monad.State                   as State
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Char8                 as BS8
import qualified Data.ByteString.Lazy                  as LBS
import           Data.IORef                            (atomicModifyIORef',
                                                        newIORef)
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (Connected),
                                                        PlainTextClient,
                                                        TLSClient)
import           Database.Redis.Cluster                (ClusterNode (..),
                                                        ClusterTopology (..),
                                                        NodeAddress (..))
import           Database.Redis.Cluster.Client         (ClusterClient (..),
                                                        ClusterCommandClient,
                                                        ClusterConfig (..),
                                                        closeClusterClient,
                                                        createClusterClient,
                                                        refreshTopology,
                                                        runClusterCommandClient)
import           Database.Redis.Cluster.ConnectionPool (PoolConfig (..))
import           Database.Redis.Command                (ClientState (..),
                                                        RedisCommandClient (..),
                                                        RedisCommands (..),
                                                        encodeCommand,
                                                        parseWith,
                                                        runRedisCommandClient,
                                                        showBS)
import           Database.Redis.Connector              (clusterTLSConnector,
                                                        connectPlaintext,
                                                        connectTLS)
import           Database.Redis.Resp                   (RespData (..))
import           Database.Redis.Standalone             (StandaloneClient,
                                                        StandaloneCommandClient,
                                                        closeStandaloneClient,
                                                        createStandaloneClient,
                                                        runStandaloneClient)
import           System.Environment                    (lookupEnv, setEnv,
                                                        unsetEnv)
import           System.Timeout                        (timeout)
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Direct standalone TLS" $ do
    it "validates the certificate and supports PING and SET/GET" $
      bracket (connectTLS "standalone.redis.test" 6380) close $ \connection -> do
        runDirect connection ping `shouldReturn` RespSimpleString "PONG"
        runDirect connection (set "direct:tls:key" "value")
          `shouldReturn` RespSimpleString "OK"
        runDirect connection (get "direct:tls:key")
          `shouldReturn` RespBulkString "value"

    it "rejects a wrong certificate hostname" $
      withEnv "REDIS_CLIENT_TLS_INSECURE" Nothing $ do
        result <- try $
          clusterTLSConnector "wrong.redis.test"
            (NodeAddress "standalone-target.local" 6380)
          :: IO (Either SomeException (TLSClient 'Connected))
        result `shouldSatisfyLeft` "wrong-hostname TLS connection unexpectedly succeeded"

    it "rejects a server certificate signed by an untrusted CA" $
      withEnv "REDIS_CLIENT_TLS_INSECURE" Nothing $
        withEnv "SSL_CERT_FILE" (Just "/certs/untrusted-ca.crt") $
          withEnv "SYSTEM_CERTIFICATE_PATH" (Just "/certs/untrusted-ca.crt") $ do
            result <- try $ connectTLS "standalone.redis.test" 6380
              :: IO (Either SomeException (TLSClient 'Connected))
            result `shouldSatisfyLeft` "untrusted-CA TLS connection unexpectedly succeeded"

    it "keeps insecure TLS as an explicit compatibility case" $
      withEnv "REDIS_CLIENT_TLS_INSECURE" (Just "1") $
        bracket
          (clusterTLSConnector "wrong.redis.test"
            (NodeAddress "standalone-target.local" 6380))
          close $ \connection ->
            runDirect connection ping `shouldReturn` RespSimpleString "PONG"

    it "matches plaintext behavior under validated multiplexed concurrency" $
      bracket createTLSStandalone closeStandaloneClient $ \client -> do
        runStandalone client ping `shouldReturn` RespSimpleString "PONG"
        results <- mapConcurrently
          (\n -> do
            let key = "standalone:tls:concurrent:" <> showBS n
                value = "value:" <> showBS n
            _ <- runStandalone client $ set key value
            runStandalone client $ get key)
          [1 .. 50 :: Int]
        results `shouldBe`
          [RespBulkString ("value:" <> showBS n) | n <- [1 .. 50 :: Int]]

    it "closes the standalone multiplexer terminally" $ do
      withPlaintextControls [standaloneControlNode] $ \controls -> do
        baseline <- establishControlBaseline controls
        bracketOnError createTLSStandalone closeStandaloneClient $ \client -> do
          runStandalone client ping `shouldReturn` RespSimpleString "PONG"
          _ <- waitForNormalClientCounts
            "standalone TLS connection did not appear in CLIENT LIST"
            controls
            (countsAbove baseline)
          closeStandaloneClient client
          _ <- waitForNormalClientCounts
            "standalone TLS connection remained after close"
            controls
            (== baseline)
          assertPostCloseFailure $ runStandalone client ping

  describe "TLS cluster connector" $ do
    it "discovers advertised node addresses distinct from the certificate hostname" $
      bracket createTLSCluster closeClusterClient $ \client -> do
        topology <- readTVarIO $ clusterTopology client
        let hosts = map (nodeHost . nodeAddress) $ Map.elems $ topologyNodes topology
        length hosts `shouldBe` 3
        hosts `shouldSatisfy` all (/= "cluster.redis.test")
        hosts `shouldSatisfy` all (/= "")

    it "matches plaintext PING and SET/GET behavior" $
      bracket createTLSCluster closeClusterClient $ \client -> do
        runCluster client ping `shouldReturn` RespSimpleString "PONG"
        runCluster client (set "cluster:tls:key" "value")
          `shouldReturn` RespSimpleString "OK"
        runCluster client (get "cluster:tls:key")
          `shouldReturn` RespBulkString "value"

    it "refreshes topology over validated TLS" $
      bracket createTLSCluster closeClusterClient $ \client -> do
        initialUpdate <- topologyUpdateTime <$> readTVarIO (clusterTopology client)
        threadDelay 100000
        refreshTopology client
        refreshedUpdate <- topologyUpdateTime <$> readTVarIO (clusterTopology client)
        refreshedUpdate `shouldSatisfy` (> initialUpdate)

    it "routes concurrent SET/GET operations over validated TLS" $
      bracket createTLSCluster closeClusterClient $ \client -> do
        results <- mapConcurrently
          (\n -> do
            let key = "cluster:tls:concurrent:" <> showBS n
                value = "value:" <> showBS n
            _ <- runCluster client $ set key value
            runCluster client $ get key)
          [1 .. 60 :: Int]
        results `shouldBe`
          [RespBulkString ("value:" <> showBS n) | n <- [1 .. 60 :: Int]]

    it "closes all cluster transports and rejects later work" $ do
      withPlaintextControls clusterControlNodes $ \controls -> do
        baseline <- establishControlBaseline controls
        bracketOnError createTLSCluster closeClusterClient $ \client -> do
          establishClusterTLSConnections client controls baseline
          closeClusterClient client
          _ <- waitForNormalClientCounts
            "cluster TLS connections remained after close"
            controls
            (== baseline)
          assertPostCloseFailure $ runCluster client ping

runDirect
  :: TLSClient 'Connected
  -> RedisCommandClient TLSClient a
  -> IO a
runDirect connection command =
  State.evalStateT
    (runRedisCommandClient command)
    (ClientState connection BS.empty)

standaloneNode :: NodeAddress
standaloneNode = NodeAddress "standalone-target.local" 6380

standaloneControlNode :: NodeAddress
standaloneControlNode = NodeAddress "standalone-target.local" 6379

clusterControlNodes :: [NodeAddress]
clusterControlNodes =
  [ NodeAddress "cluster-node1.local" 6379
  , NodeAddress "cluster-node2.local" 6379
  , NodeAddress "cluster-node3.local" 6379
  ]

createTLSStandalone :: IO StandaloneClient
createTLSStandalone =
  createStandaloneClient
    (clusterTLSConnector "standalone.redis.test")
    standaloneNode

runStandalone
  :: StandaloneClient
  -> StandaloneCommandClient RespData
  -> IO RespData
runStandalone = runStandaloneClient

createTLSCluster :: IO (ClusterClient TLSClient)
createTLSCluster =
  createClusterClient config $ clusterTLSConnector "cluster.redis.test"
  where
    config = ClusterConfig
      { clusterSeedNode = NodeAddress "cluster-node1.local" 6380
      , clusterPoolConfig = PoolConfig
          { maxConnectionsPerNode = 2
          , connectionTimeout = 5
          , maxRetries = 3
          , useTLS = True
          }
      , clusterMaxRetries = 3
      , clusterRetryDelay = 100000
      , clusterTopologyRefreshInterval = 600
      }

runCluster
  :: ClusterClient TLSClient
  -> ClusterCommandClient TLSClient RespData
  -> IO RespData
runCluster = runClusterCommandClient

withPlaintextControls
  :: [NodeAddress]
  -> ([PlainTextClient 'Connected] -> IO a)
  -> IO a
withPlaintextControls nodes action = acquire nodes []
  where
    acquire [] controls = action $ reverse controls
    acquire (NodeAddress host port : remaining) controls =
      bracket
        (connectPlaintext host port)
        close
        (\control -> acquire remaining (control : controls))

establishControlBaseline
  :: [PlainTextClient 'Connected]
  -> IO [Int]
establishControlBaseline controls = do
  samples <- newIORef Nothing
  pollUntil
    "plaintext control connections did not reach a stable baseline" $ do
      counts <- mapM normalClientCount controls
      atomicModifyIORef' samples $ \previous ->
        let stableSamples = case previous of
              Just (previousCounts, sampleCount)
                | previousCounts == counts -> sampleCount + 1
              _ -> 1
            next = Just (counts, stableSamples)
            result
              | stableSamples >= 5 = Just counts
              | otherwise = Nothing
        in (next, result)

establishClusterTLSConnections
  :: ClusterClient TLSClient
  -> [PlainTextClient 'Connected]
  -> [Int]
  -> IO ()
establishClusterTLSConnections client controls baseline = do
  forM_ [1 .. 300 :: Int] $ \n -> do
    let key = "cluster:tls:cleanup:" <> showBS n
        value = "value:" <> showBS n
    runCluster client (set key value) `shouldReturn` RespSimpleString "OK"
    runCluster client (get key) `shouldReturn` RespBulkString value
  _ <- waitForNormalClientCounts
    "TLS connections were not established to every cluster node"
    controls
    (countsAbove baseline)
  return ()

countsAbove :: [Int] -> [Int] -> Bool
countsAbove baseline counts =
  length counts == length baseline
    && and (zipWith (>) counts baseline)

waitForNormalClientCounts
  :: String
  -> [PlainTextClient 'Connected]
  -> ([Int] -> Bool)
  -> IO [Int]
waitForNormalClientCounts description controls predicate =
  pollUntil description $ do
    counts <- mapM normalClientCount controls
    return $ if predicate counts then Just counts else Nothing

pollUntil :: String -> IO (Maybe a) -> IO a
pollUntil description check = do
  result <- timeout 5000000 loop
  case result of
    Just value -> return value
    Nothing    -> expectationFailure description >> fail description
  where
    loop = do
      outcome <- check
      case outcome of
        Just value -> return value
        Nothing    -> threadDelay 20000 >> loop

normalClientCount :: PlainTextClient 'Connected -> IO Int
normalClientCount connection = do
  response <- runPlaintextRaw connection ["CLIENT", "LIST", "TYPE", "NORMAL"]
  case response of
    RespBulkString payload ->
      return $ length $ filter (not . BS.null) $ BS8.lines payload
    other ->
      fail $ "Unexpected CLIENT LIST response: " ++ show other

runPlaintextRaw
  :: PlainTextClient 'Connected
  -> [BS.ByteString]
  -> IO RespData
runPlaintextRaw connection arguments =
  State.evalStateT
    (runRedisCommandClient $ RedisCommandClient $ do
      ClientState connected _ <- State.get
      liftIO $ send connected $ LBS.fromStrict $ encodeCommand arguments
      parseWith $ liftIO $ receive connected)
    (ClientState connection BS.empty)

assertPostCloseFailure :: IO RespData -> Expectation
assertPostCloseFailure command = do
  outcome <- timeout 2000000 $
    try command :: IO (Maybe (Either SomeException RespData))
  outcome `shouldSatisfy` maybe False isLeft

withEnv :: String -> Maybe String -> IO a -> IO a
withEnv name value action =
  bracket (lookupEnv name) restore $ \_ -> setRequested >> action
  where
    setRequested = maybe (unsetEnv name) (setEnv name) value
    restore previous = maybe (unsetEnv name) (setEnv name) previous

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

shouldSatisfyLeft :: Either a b -> String -> Expectation
shouldSatisfyLeft (Left _) _        = return ()
shouldSatisfyLeft (Right _) message = expectationFailure message

infix 1 `shouldSatisfyLeft`
