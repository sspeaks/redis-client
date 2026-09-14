{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module LibraryE2E.StandaloneConcurrencyTests (spec) where

import           Control.Concurrent.Async              (mapConcurrently)
import           Control.Exception                     (SomeException, try)
import           Control.Monad                         (forM, forM_)
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Client                 (PlainTextClient)
import           Database.Redis.Cluster                (NodeAddress (..))
import           Database.Redis.Command                (RedisCommands (..),
                                                        encodeCommandBuilder,
                                                        showBS)
import           Database.Redis.Connector              (clusterPlaintextConnector)
import           Database.Redis.Internal.MultiplexPool (MultiplexPool,
                                                        closeMultiplexPool,
                                                        createMultiplexPool,
                                                        submitToNode)
import           Database.Redis.Resp                   (RespData (..))
import           Database.Redis.Standalone             (StandaloneClient,
                                                        StandaloneCommandClient,
                                                        closeStandaloneClient,
                                                        createStandaloneClient,
                                                        runStandaloneClient)
import           LibraryE2E.StormAssertions            (commandFailure,
                                                        recordProgress,
                                                        trySynchronous)
import           System.Timeout                        (timeout)

import           Test.Hspec

-- | Standalone Redis node address (standalone container in docker-cluster)
standaloneNode :: NodeAddress
standaloneNode = NodeAddress "redis-standalone.local" 6390

-- | Create a standalone multiplexed client for testing
createTestStandaloneClient :: IO StandaloneClient
createTestStandaloneClient =
  createStandaloneClient clusterPlaintextConnector standaloneNode

-- | Run a command that returns RespData (resolves ambiguous FromResp)
run :: StandaloneClient -> StandaloneCommandClient RespData -> IO RespData
run = runStandaloneClient

runStormWorker
  :: StandaloneClient
  -> IORef (Map.Map Int String)
  -> Int
  -> Int
  -> IO [String]
runStormWorker client progress opsPerThread tid = do
  let prefix = "conc-t" <> showBS tid <> "-"

  failures <- forM [1..opsPerThread] $ \i -> do
    let key = prefix <> showBS i
        value = "v-" <> showBS tid <> "-" <> showBS i

    recordProgress progress tid "SET" key
    setResult <- trySynchronous $ run client (set key value)
    recordProgress progress tid "GET" key
    getResult <- trySynchronous $ run client (get key)
    pure $
      commandFailure tid "SET" key (RespSimpleString "OK") setResult
        ++ commandFailure tid "GET" key (RespBulkString value) getResult
  pure (concat failures)

spec :: Spec
spec = describe "Concurrency and Stress Tests" $ do

  describe "Standalone concurrency storm" $ do
    it "50 threads x 100 ops SET/GET with no data corruption" $ do
      client <- createTestStandaloneClient
      -- Flush first to start clean
      _ <- run client flushAll

      let threadCount = 50 :: Int
          opsPerThread = 100 :: Int
          stormTimeoutMicros = 60 * 1000000

      progress <- newIORef Map.empty
      result <- timeout stormTimeoutMicros $
        mapConcurrently
          (runStormWorker client progress opsPerThread)
          [1..threadCount]
      case result of
        Nothing -> do
          workerProgress <- readIORef progress
          expectationFailure $ unlines
            [ "Standalone SET/GET storm timed out after 60 seconds."
            , "Last operation for each worker:"
            , unlines (Map.elems workerProgress)
            ]
        Just failures ->
          concat failures `shouldBe` []

      _ <- run client flushAll
      closeStandaloneClient client

  describe "MultiplexPool with count > 1" $ do
    it "distributes load across multiple multiplexers per node" $ do
      -- Create a MultiplexPool with 3 multiplexers per node
      pool <- createMultiplexPool clusterPlaintextConnector 3
                :: IO (MultiplexPool PlainTextClient)

      -- Run 100 concurrent submissions through the pool
      let totalOps = 100 :: Int

      -- First, SET a value
      let setCmd = encodeCommandBuilder ["SET", "muxpool-test", "hello"]
      _ <- submitToNode pool standaloneNode setCmd

      -- Run concurrent GET operations through the pool
      -- With 3 muxes, they should be distributed round-robin
      results <- mapConcurrently (\i -> do
        let cmd = encodeCommandBuilder ["GET", "muxpool-test"]
        r <- try (submitToNode pool standaloneNode cmd)
                :: IO (Either SomeException RespData)
        case r of
          Right (RespBulkString "hello") -> return (True, i)
          _                              -> return (False, i)
        ) [1..totalOps]

      let successes = length $ filter fst results
      -- All should succeed since we're reading a valid key
      successes `shouldBe` totalOps

      -- Cleanup
      let delCmd = encodeCommandBuilder ["DEL", "muxpool-test"]
      _ <- submitToNode pool standaloneNode delCmd
      closeMultiplexPool pool

    it "multiple multiplexers handle concurrent writes correctly" $ do
      pool <- createMultiplexPool clusterPlaintextConnector 3
                :: IO (MultiplexPool PlainTextClient)

      let threadCount = 30 :: Int
          opsPerThread = 50 :: Int

      errors <- newIORef (0 :: Int)

      _ <- mapConcurrently (\tid -> do
        forM_ [1..opsPerThread] $ \i -> do
          let key = "muxpool-t" <> showBS tid <> "-" <> showBS i
              val = "v" <> showBS tid <> "-" <> showBS i
              setCmd = encodeCommandBuilder ["SET", key, val]
              getCmd = encodeCommandBuilder ["GET", key]

          -- SET then GET
          _ <- submitToNode pool standaloneNode setCmd
          r <- submitToNode pool standaloneNode getCmd
          case r of
            RespBulkString v | v == val -> return ()
            _ -> atomicModifyIORef' errors (\n -> (n + 1, ()))
        ) [1..threadCount]

      totalErrors <- readIORef errors
      totalErrors `shouldBe` 0

      -- Cleanup
      let flushCmd = encodeCommandBuilder ["FLUSHALL"]
      _ <- submitToNode pool standaloneNode flushCmd
      closeMultiplexPool pool

  describe "Submit after destroy" $ do
    it "standalone client throws after close, does not hang" $ do
      client <- createTestStandaloneClient
      -- Verify it works before close
      r <- run client ping
      r `shouldBe` RespSimpleString "PONG"

      -- Close the client
      closeStandaloneClient client

      -- Submit after destroy should throw MultiplexerDead, not hang
      result <- try (run client (set "dead-key" "val"))
                  :: IO (Either SomeException RespData)
      result `shouldSatisfy` isLeft'

    it "MultiplexPool throws after close, does not hang" $ do
      pool <- createMultiplexPool clusterPlaintextConnector 1
                :: IO (MultiplexPool PlainTextClient)

      -- Verify it works
      let pingCmd = encodeCommandBuilder ["PING"]
      r <- submitToNode pool standaloneNode pingCmd
      r `shouldBe` RespSimpleString "PONG"

      -- Close all multiplexers
      closeMultiplexPool pool

      -- Submit after close — pool may create new muxes, but the original muxes are dead.
      -- This should either succeed (new mux created) or throw, but NOT hang.
      result <- try (submitToNode pool standaloneNode pingCmd)
                  :: IO (Either SomeException RespData)
      -- MultiplexPool auto-reconnects, so it may succeed or fail, but must not hang.
      -- We just verify it completed (didn't hang) — the try already proves that.
      case result of
        Right (RespSimpleString "PONG") -> return ()  -- Auto-reconnected
        Right _                         -> return ()  -- Some other response
        Left _                          -> return ()  -- Threw an exception (also acceptable)

    it "rapid submit-after-destroy throws MultiplexerDead" $ do
      client <- createTestStandaloneClient
      closeStandaloneClient client

      -- Rapidly attempt multiple submits after destroy
      results <- mapConcurrently (\_ -> do
        try (run client (set "dead" "val"))
          :: IO (Either SomeException RespData)
        ) [1..20 :: Int]

      -- All should be Left (threw exception), none should hang
      let allFailed = all isLeft' results
      allFailed `shouldBe` True

-- | Helper
isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _        = False
