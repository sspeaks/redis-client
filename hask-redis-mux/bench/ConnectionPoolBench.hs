{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

module Main (main) where

import           Control.Concurrent                    (getNumCapabilities,
                                                        newEmptyMVar, putMVar,
                                                        setNumCapabilities,
                                                        takeMVar, threadDelay)
import           Control.Concurrent.Async              (async, mapConcurrently,
                                                        wait)
import           Control.Monad                         (forM, forM_,
                                                        replicateM_, when)
import           Data.IORef                            (atomicModifyIORef',
                                                        newIORef, readIORef)
import           Data.List                             (sort)
import qualified Data.Map.Strict                       as Map
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (NodeAddress (..))
import           Database.Redis.Cluster.ConnectionPool
import           GHC.Clock                             (getMonotonicTimeNSec)
import           System.Environment                    (getArgs)
import           Text.Printf                           (printf)

data BenchClient (a :: ConnectionStatus) where
  BenchConnected :: BenchClient 'Connected

instance Client BenchClient where
  connect = error "unused"
  close _ = return ()
  send _ _ = return ()
  receive _ = return mempty

main :: IO ()
main = do
  args <- getArgs
  let requestedCapabilities =
        case args of
          [value] -> read value
          _       -> 1
  setNumCapabilities requestedCapabilities
  capabilities <- getNumCapabilities
  printf "source=ConnectionPoolBench caps=%d\n" capabilities
  forM_ [1, 8, 64] $ \nodeCount ->
    forM_ [1, 4, 16] $ \capacity ->
      forM_ [8, 64, 512] $ \waiterCount ->
        runCase capabilities nodeCount capacity waiterCount

runCase :: Int -> Int -> Int -> Int -> IO ()
runCase capabilities nodeCount capacity waiterCount = do
  let config = PoolConfig capacity 5 0 False
      addresses =
        [NodeAddress ("benchmark-" <> show index) 6379 | index <- [0 .. nodeCount - 1]]
      holderCount = nodeCount * capacity
      idleOperations = max nodeCount (capabilities * nodeCount * 64)
  pool <- createPool config
  connectionCounts <- newIORef (Map.empty :: Map.Map NodeAddress Int)
  let connector address = do
        atomicModifyIORef' connectionCounts $ \counts ->
          (Map.insertWith (+) address 1 counts, ())
        return BenchConnected

  releaseHolders <- newEmptyMVar
  holderStarted <- newEmptyMVar
  holders <- forM [(address, slot) | address <- addresses, slot <- [1 .. capacity]] $
    \(address, _) -> async $ withConnection pool address connector $ \_ -> do
      putMVar holderStarted ()
      takeMVar releaseHolders
  replicateM_ holderCount (takeMVar holderStarted)

  completionOrder <- newIORef Map.empty
  let waiterAssignments = zip [1 .. waiterCount] (cycle addresses)
      expectedOrders = Map.fromListWith (++)
        [(address, [waiterIndex]) | (waiterIndex, address) <- waiterAssignments]
  waiters <- forM waiterAssignments $ \(waiterIndex, address) ->
    do
      waiter <- async $ do
        started <- getMonotonicTimeNSec
        withConnection pool address connector $ \_ ->
          atomicModifyIORef' completionOrder $ \completed ->
            (Map.insertWith (flip (++)) address [waiterIndex] completed, ())
        finished <- getMonotonicTimeNSec
        return (finished - started)
      awaitWaiters pool address ((waiterIndex - 1) `div` nodeCount + 1)
      return waiter

  idlePool <- createPool config
  let idleOperation address = do
        started <- getMonotonicTimeNSec
        withConnection idlePool address connector $ \_ -> return ()
        finished <- getMonotonicTimeNSec
        return (finished - started)
  mixedSamples <- mapConcurrently idleOperation (take idleOperations $ cycle addresses)
  handoffStarted <- getMonotonicTimeNSec
  replicateM_ holderCount (putMVar releaseHolders ())
  waiterSamples <- mapM wait waiters
  mapM_ wait holders
  handoffFinished <- getMonotonicTimeNSec
  completed <- readIORef completionOrder
  createdByNode <- readIORef connectionCounts
  when (Map.size createdByNode /= nodeCount) $
    fail "benchmark did not create connections for every requested node"
  closePool idlePool
  let handoffSeconds =
        fromIntegral (handoffFinished - handoffStarted) / 1.0e9 :: Double
      handoffThroughput = fromIntegral waiterCount / handoffSeconds :: Double
      fifoViolations = sum
        [ length $ filter id $ zipWith (/=)
            (Map.findWithDefault [] address completed)
            expected
        | (address, expected) <- Map.toList expectedOrders
        ]
      created = sum $ Map.elems createdByNode
  printf
    "nodes=%d capacity=%d waiters=%d created=%d handoff_ops_s=%.2f waiter_p50_us=%.2f waiter_p95_us=%.2f waiter_p99_us=%.2f mixed_idle_p50_us=%.2f mixed_idle_p95_us=%.2f mixed_idle_p99_us=%.2f fifo_violations=%d\n"
    nodeCount
    capacity
    waiterCount
    created
    handoffThroughput
    (percentile 50 waiterSamples)
    (percentile 95 waiterSamples)
    (percentile 99 waiterSamples)
    (percentile 50 mixedSamples)
    (percentile 95 mixedSamples)
    (percentile 99 mixedSamples)
    fifoViolations
  closePool pool

awaitWaiters :: ConnectionPool client -> NodeAddress -> Int -> IO ()
awaitWaiters pool address expected = do
  stats <- getConnectionPoolStats pool address
  when (statsWaitingCallers stats /= expected) $ do
    threadDelay 1000
    awaitWaiters pool address expected

percentile :: Integral a => Int -> [a] -> Double
percentile _ [] = 0
percentile p samples =
  fromIntegral (sorted !! min (length sorted - 1) ((length sorted * p) `div` 100))
    / 1000
  where
  sorted = sort samples
