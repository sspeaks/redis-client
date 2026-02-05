{-# LANGUAGE OverloadedStrings #-}

module ClusterE2E.Tunnel (spec) where

import           Client                     (PlainTextClient (NotConnectedPlainTextClient), connect, close)
import           Cluster                    (NodeAddress (..), NodeRole (..),
                                             ClusterNode (..), ClusterTopology (..), )
import           ClusterCommandClient       (closeClusterClient, clusterTopology)
import           ClusterE2E.Utils
import           ClusterSlotMapping         (getKeyForNode)
import           Control.Concurrent.STM     (readTVarIO)
import           Control.Exception          (IOException, bracket, finally, try)
import           Control.Monad              (when, forM_)
import qualified Data.ByteString.Char8      as BSC
import           Data.List                  (isInfixOf)
import qualified Data.Map.Strict            as Map
import           RedisCommandClient         (RedisCommands (..))
import           Resp                       (RespData (..))
import           System.IO                  (hSetBuffering, BufferMode(..))
import           System.Process             (proc, withCreateProcess, CreateProcess(..), StdStream(..))
import           System.Timeout             (timeout)
import           Test.Hspec

spec :: Spec
spec = describe "Cluster Tunnel Mode" $ do
  describe "Smart Proxy Mode" $ do
    it "smart mode makes cluster appear as single Redis instance" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  -- Wait for smart proxy to start listening
                  ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure (unlines ["Smart proxy did not report listening within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
                    Just (Left err) -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure (unlines ["Smart proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
                    Just (Right ()) -> do
                      -- Connect to the smart proxy as if it were a single Redis instance
                      conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                      
                      -- Execute commands through proxy
                      result1 <- runRedisCommand conn (set "smart:key1" "value1")
                      result1 `shouldBe` RespSimpleString "OK"
                      
                      result2 <- runRedisCommand conn (get "smart:key1")
                      result2 `shouldBe` RespBulkString "value1"
                      
                      result3 <- runRedisCommand conn ping
                      result3 `shouldBe` RespSimpleString "PONG"
                      
                      close conn
                      
                      -- Verify that commands routed transparently by checking with cluster client
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        verifyResult <- runCmd client (get "smart:key1")
                        verifyResult `shouldBe` RespBulkString "value1"
                        
                        -- Clean up the test key
                        _ <- runCmd client (del ["smart:key1"])
                        pure ()
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Smart proxy process did not expose stdout/stderr handles"

    it "smart mode handles commands that route to different nodes" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Smart proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Smart proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      -- Get cluster topology to determine which nodes exist
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        topology <- readTVarIO (clusterTopology client)
                        let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                        
                        when (length masterNodes < 2) $
                          expectationFailure "Need at least 2 master nodes for this test"
                        
                        -- Find keys that hash to different nodes
                        let (node1:node2:_) = masterNodes
                            key1 = BSC.unpack $ getKeyForNode node1 "key1"
                            key2 = BSC.unpack $ getKeyForNode node2 "key2"
                        
                        conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                        
                        -- Set keys that will route to different nodes
                        _ <- runRedisCommand conn (set key1 "value-node1")
                        _ <- runRedisCommand conn (set key2 "value-node2")
                        
                        -- Verify all keys are accessible through the proxy (proving cross-node routing)
                        result1 <- runRedisCommand conn (get key1)
                        result1 `shouldBe` RespBulkString "value-node1"
                        
                        result2 <- runRedisCommand conn (get key2)
                        result2 `shouldBe` RespBulkString "value-node2"
                        
                        close conn
                        
                        -- Clean up - use cluster client to handle routing per key
                        _ <- runCmd client (del [key1])
                        _ <- runCmd client (del [key2])
                        pure ()
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Smart proxy process did not expose stdout/stderr handles"

    it "smart mode works with various keys" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Smart proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Smart proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      conn <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                      
                      -- Set a key - smart proxy should route correctly regardless of which node owns the slot
                      result1 <- runRedisCommand conn (set "various:test" "value")
                      result1 `shouldBe` RespSimpleString "OK"
                      
                      -- Get the key - should work regardless of topology
                      result2 <- runRedisCommand conn (get "various:test")
                      result2 `shouldBe` RespBulkString "value"
                      
                      close conn
                      
                      -- Clean up
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        _ <- runCmd client (del ["various:test"])
                        pure ()
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Smart proxy process did not expose stdout/stderr handles"

    it "smart mode handles multiple separate connections" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "smart"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Smart proxy listening on localhost:6379") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Smart proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Smart proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      -- Create two separate connections
                      conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                      conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just 6379))
                      
                      -- Client 1 sets and gets a key
                      result1 <- runRedisCommand conn1 (set "multi:key1" "client1-value")
                      result1 `shouldBe` RespSimpleString "OK"
                      
                      -- Client 2 sets and gets a different key
                      result2 <- runRedisCommand conn2 (set "multi:key2" "client2-value")
                      result2 `shouldBe` RespSimpleString "OK"
                      
                      -- Both clients can read their keys
                      result3 <- runRedisCommand conn1 (get "multi:key1")
                      result3 `shouldBe` RespBulkString "client1-value"
                      
                      result4 <- runRedisCommand conn2 (get "multi:key2")
                      result4 `shouldBe` RespBulkString "client2-value"
                      
                      -- Cross-client reads work
                      result5 <- runRedisCommand conn1 (get "multi:key2")
                      result5 `shouldBe` RespBulkString "client2-value"
                      
                      result6 <- runRedisCommand conn2 (get "multi:key1")
                      result6 `shouldBe` RespBulkString "client1-value"
                      
                      close conn1
                      close conn2
                      
                      -- Clean up
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        _ <- runCmd client (del ["multi:key1"])
                        _ <- runCmd client (del ["multi:key2"])
                        pure ()
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Smart proxy process did not expose stdout/stderr handles"

  describe "Pinned Proxy Mode" $ do
    it "pinned mode creates one listener per cluster node and each works correctly" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  -- Wait for pinned proxy to start all listeners
                  ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure (unlines ["Pinned proxy did not report all listeners started within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
                    Just (Left err) -> do
                      cleanup
                      stdoutRest <- drainHandle hout
                      stderrRest <- drainHandle herr
                      expectationFailure (unlines ["Pinned proxy stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
                    Just (Right ()) -> do
                      -- Get cluster topology to find master nodes
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        topology <- readTVarIO (clusterTopology client)
                        let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                        
                        -- Verify we have multiple masters
                        length masterNodes `shouldSatisfy` (>= 3)
                        
                        -- Test each pinned listener
                        forM_ masterNodes $ \masterNode -> do
                          let addr = nodeAddress masterNode
                              localPort = nodePort addr
                              -- Get a key that hashes to a slot owned by this node
                              testKey = BSC.unpack $ getKeyForNode masterNode "test"
                          
                          conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))
                          
                          -- Execute a command through pinned proxy using a key that belongs to this node
                          result1 <- runRedisCommand conn (set testKey "value")
                          result1 `shouldBe` RespSimpleString "OK"
                          
                          result2 <- runRedisCommand conn (get testKey)
                          result2 `shouldBe` RespBulkString "value"
                          
                          close conn
                          
                          -- Clean up
                          _ <- runCmd client (del [testKey])
                          pure ()
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

    it "pinned mode listeners forward to their respective nodes" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Pinned proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Pinned proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      -- Get cluster topology
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        topology <- readTVarIO (clusterTopology client)
                        let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                        
                        when (length masterNodes < 2) $
                          expectationFailure "Need at least 2 master nodes for this test"
                        
                        -- Connect to two different pinned listeners
                        case masterNodes of
                          (node1:node2:_) -> do
                            let addr1 = nodeAddress node1
                                addr2 = nodeAddress node2
                                port1 = nodePort addr1
                                port2 = nodePort addr2
                                -- Find slots owned by each node
                                -- Get keys that hash to slots owned by those nodes
                                testKey1 = BSC.unpack $ getKeyForNode node1 "node1"
                                testKey2 = BSC.unpack $ getKeyForNode node2 "node2"
                            
                            conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just port1))
                            conn2 <- connect (NotConnectedPlainTextClient "localhost" (Just port2))
                            
                            -- Set a key through each listener using keys that belong to those nodes
                            _ <- runRedisCommand conn1 (set testKey1 "from-node1")
                            _ <- runRedisCommand conn2 (set testKey2 "from-node2")
                            
                            -- Verify keys are set
                            result1 <- runRedisCommand conn1 (get testKey1)
                            result1 `shouldBe` RespBulkString "from-node1"
                            
                            result2 <- runRedisCommand conn2 (get testKey2)
                            result2 `shouldBe` RespBulkString "from-node2"
                            
                            close conn1
                            close conn2
                            
                            -- Clean up (delete keys separately to avoid CROSSSLOTS error)
                            _ <- runCmd client (del [testKey1])
                            _ <- runCmd client (del [testKey2])
                            pure ()
                          _ -> expectationFailure "Expected at least 2 master nodes"
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

    it "pinned mode returns MOVED errors for keys not owned by the node" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Pinned proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Pinned proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        topology <- readTVarIO (clusterTopology client)
                        let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                        
                        when (length masterNodes < 2) $
                          expectationFailure "Need at least 2 master nodes for this test"
                        
                        -- Get two different nodes
                        case masterNodes of
                          (node1:node2:_) -> do
                            let addr1 = nodeAddress node1
                                port1 = nodePort addr1
                                -- Find a slot owned by node2 (NOT node1)
                                -- Get a key that hashes to a slot owned by node2 (NOT node1)
                                wrongKey = BSC.unpack $ getKeyForNode node2 "wrong"
                            
                            -- Connect to node1's pinned listener
                            conn1 <- connect (NotConnectedPlainTextClient "localhost" (Just port1))
                            
                            -- Try to access a key that belongs to node2 - should get MOVED error
                            result <- runRedisCommand conn1 (get wrongKey)
                            case result of
                              RespError err -> do
                                -- Verify it's a MOVED error
                                err `shouldSatisfy` \e -> "MOVED" `isInfixOf` e
                              _ -> expectationFailure $ "Expected MOVED error, got: " ++ show result
                            
                            close conn1
                          _ -> expectationFailure "Expected at least 2 master nodes"
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Pinned proxy process did not expose stdout/stderr handles"

    it "pinned mode rewrites CLUSTER SLOTS addresses to 127.0.0.1" $ do
      redisClient <- getRedisClientPath
      let cp = (proc redisClient ["tunn", "--host", "redis1.local", "--cluster", "--tunnel-mode", "pinned"])
                 { std_out = CreatePipe,
                   std_err = CreatePipe
                 }
      withCreateProcess cp $ \_ mOut mErr ph ->
        case (mOut, mErr) of
          (Just hout, Just herr) -> do
            hSetBuffering hout LineBuffering
            hSetBuffering herr LineBuffering
            let cleanup = cleanupProcess ph
            finally
              (do
                  ready <- timeout (10 * 1000000) (try (waitForSubstring hout "All pinned listeners started") :: IO (Either IOException ()))
                  case ready of
                    Nothing -> do
                      cleanup
                      expectationFailure "Pinned proxy did not start within timeout"
                    Just (Left _) -> do
                      cleanup
                      expectationFailure "Pinned proxy stdout closed unexpectedly"
                    Just (Right ()) -> do
                      -- Get first master node port
                      bracket createTestClusterClient closeClusterClient $ \client -> do
                        topology <- readTVarIO (clusterTopology client)
                        let masterNodes = filter ((== Master) . nodeRole) (Map.elems $ topologyNodes topology)
                        
                        case masterNodes of
                          [] -> expectationFailure "No master nodes found in cluster topology"
                          (firstMaster:_) -> do
                            let addr      = nodeAddress firstMaster
                                localPort = nodePort addr
                            
                            conn <- connect (NotConnectedPlainTextClient "localhost" (Just localPort))
                            
                            -- Execute CLUSTER SLOTS through pinned proxy
                            -- The response should have addresses rewritten to 127.0.0.1
                            result <- runRedisCommand conn clusterSlots
                            
                            -- Verify result is an array and contains 127.0.0.1
                            case result of
                              RespArray slots -> do
                                -- Should have multiple slot ranges
                                length slots `shouldSatisfy` (> 0)
                                -- Verify addresses are rewritten to 127.0.0.1
                                let resultStr = show result
                                resultStr `shouldSatisfy` \s -> "127.0.0.1" `isInfixOf` s
                                -- Should NOT contain original hostnames
                                resultStr `shouldSatisfy` \s -> not ("redis1.local" `isInfixOf` s)
                              other -> expectationFailure $ "Expected RespArray from CLUSTER SLOTS, got: " ++ show other
                            
                            close conn
              )
              cleanup
          _ -> do
            cleanupProcess ph
            expectationFailure "Pinned proxy process did not expose stdout/stderr handles"
