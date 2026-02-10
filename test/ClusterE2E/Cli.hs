{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Cli (spec) where

import           Client                     (PlainTextClient (NotConnectedPlainTextClient), connect, close)
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..), SlotRange(..),
                                             calculateSlot, findNodeForSlot)
import           ClusterCommandClient       (closeClusterClient, clusterTopology)
import           ClusterE2E.Utils
import           SlotMappingHelpers         (getKeyForNode)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (bracket)
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy       as BSL
import           Data.Char                  (toLower)
import           Data.List                  (isInfixOf, nub)
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))
import           System.Exit                (ExitCode (..))
import           Test.Hspec

spec :: Spec
spec = describe "Cluster CLI Mode" $ do
  it "cli mode can execute GET/SET commands" $ do
    (exitCode, stdoutOut) <- withCliSession
      [ "SET cli:test:key value123"
      , "GET cli:test:key"
      ]
    exitCode `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("value123" `isInfixOf`)

  it "cli mode can execute keyless commands (PING)" $ do
    (exitCode, stdoutOut) <- withCliSession ["PING"]
    exitCode `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("PONG" `isInfixOf`)

  it "cli mode can execute CLUSTER SLOTS command" $ do
    (exitCode, stdoutOut) <- withCliSession ["CLUSTER SLOTS"]
    exitCode `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` (\s -> "redis1.local" `isInfixOf` s || "redis2.local" `isInfixOf` s)

  it "cli mode handles hash tags correctly" $ do
    bracket createTestClusterClient closeClusterClient $ \client -> do
      topology <- readTVarIO (clusterTopology client)
      let masterNodes = [node | node <- Map.elems (topologyNodes topology), nodeRole node == Master]

      -- Set keys through CLI using hash tags that route to specific nodes
      let commands = concatMap (\node ->
            case nodeSlotsServed node of
              (range:_) ->
                let slot = slotStart range
                    keyBS = getKeyForNode node ("clitest:" ++ show slot)
                    key = BSC.unpack keyBS
                    value = "node" ++ show slot
                in ["SET " ++ key ++ " " ++ value]
              _ -> []
            ) masterNodes

      (exitCode, _) <- withCliSession commands
      exitCode `shouldBe` ExitSuccess

      -- Verify each node has the key we set on it
      mapM_ (\node ->
        case nodeSlotsServed node of
          (range:_) -> do
            let slot = slotStart range
                keyBS = getKeyForNode node ("clitest:" ++ show slot)
                expectedValue = "node" ++ show slot
                addr = nodeAddress node
            conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
            result <- runRedisCommand conn (get keyBS)
            close conn
            case result of
              RespBulkString val -> val `shouldBe` BSL.fromStrict (BSC.pack expectedValue)
              other -> expectationFailure $ "Expected value on node " ++ show (nodeHost addr) ++ ", got: " ++ show other
          _ -> return ()
        ) masterNodes

  it "cli mode handles CROSSSLOT errors for multi-key commands" $ do
    (exitCode, stdoutOut) <- withCliSession ["MGET key1 key2 key3"]
    exitCode `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` (isInfixOf "crossslot" . map toLower)

  it "cli mode can execute multi-key commands on same slot using hash tags" $ do
    (exitCode, stdoutOut) <- withCliSession
      [ "SET {slot:1}:key1 value1"
      , "SET {slot:1}:key2 value2"
      , "SET {slot:1}:key3 value3"
      , "MGET {slot:1}:key1 {slot:1}:key2 {slot:1}:key3"
      ]
    exitCode `shouldBe` ExitSuccess
    stdoutOut `shouldSatisfy` ("value1" `isInfixOf`)
    stdoutOut `shouldSatisfy` ("value2" `isInfixOf`)
    stdoutOut `shouldSatisfy` ("value3" `isInfixOf`)

  it "cli mode routes commands to correct nodes" $ do
    let key1 = "route:key1"
        key2 = "route:key2"
        key3 = "route:key3"

    slot1 <- calculateSlot (BSC.pack key1)
    slot2 <- calculateSlot (BSC.pack key2)
    slot3 <- calculateSlot (BSC.pack key3)

    bracket createTestClusterClient closeClusterClient $ \client -> do
      topology <- readTVarIO (clusterTopology client)

      let findNodeBySlot s = do
            nId <- findNodeForSlot topology s
            Map.lookup nId (topologyNodes topology)
          maybeNode1 = findNodeBySlot slot1
          maybeNode2 = findNodeBySlot slot2
          maybeNode3 = findNodeBySlot slot3

      case (maybeNode1, maybeNode2, maybeNode3) of
        (Just node1, Just node2, Just node3) -> do
          let differentNodes = length (nub [nodeId node1, nodeId node2, nodeId node3]) > 1
          differentNodes `shouldBe` True

          (exitCode, _) <- withCliSession
            [ "SET " ++ key1 ++ " value1"
            , "SET " ++ key2 ++ " value2"
            , "SET " ++ key3 ++ " value3"
            ]
          exitCode `shouldBe` ExitSuccess

          -- Verify each key is on its expected node by connecting directly
          let verifyKeyOnNode key expectedNode = do
                let addr = nodeAddress expectedNode
                conn <- connect (NotConnectedPlainTextClient (nodeHost addr) (Just (nodePort addr)))
                result <- runRedisCommand conn (get (BSC.pack key))
                close conn
                case result of
                  RespBulkString val -> val `shouldSatisfy` (not . BSL.null)
                  other -> expectationFailure $ "Key " ++ key ++ " not found on expected node " ++ show (nodeHost addr) ++ ": " ++ show other

          verifyKeyOnNode key1 node1
          verifyKeyOnNode key2 node2
          verifyKeyOnNode key3 node3
        _ -> expectationFailure "Could not map slots to nodes in topology"
