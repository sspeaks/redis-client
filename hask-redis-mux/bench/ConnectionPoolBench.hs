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
      saturatedAddress = NodeAddress "benchmark-0" 6379
      idleAddress = NodeAddress "benchmark-1" 6379
      idleOperations = max 64 (capabilities * 64)
  pool <- createPool config
  connectionCount <- newIORef (0 :: Int)
  let connector _ = do
        atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
        return BenchConnected
      oneOperation address = do
        started <- getMonotonicTimeNSec
        withConnection pool address connector $ \_ -> return ()
        finished <- getMonotonicTimeNSec
        return (finished - started)

  releaseHolders <- newEmptyMVar
  holderStarted <- newEmptyMVar
  holders <- forM [1 .. capacity] $ \_ ->
    async $ withConnection pool saturatedAddress connector $ \_ -> do
      putMVar holderStarted ()
      takeMVar releaseHolders
  replicateM_ capacity (takeMVar holderStarted)

  completionOrder <- newIORef ([] :: [Int])
  waiters <- forM [1 .. waiterCount] $ \waiterIndex ->
    async $ do
      started <- getMonotonicTimeNSec
      withConnection pool saturatedAddress connector $ \_ ->
        atomicModifyIORef' completionOrder $ \completed ->
          (completed <> [waiterIndex], ())
      finished <- getMonotonicTimeNSec
      return (finished - started)
  awaitWaiters pool saturatedAddress waiterCount

  mixedSamples <-
    if nodeCount == 1
      then return []
      else mapConcurrently (const $ oneOperation idleAddress) [1 .. idleOperations]
  handoffStarted <- getMonotonicTimeNSec
  replicateM_ capacity (putMVar releaseHolders ())
  waiterSamples <- mapM wait waiters
  mapM_ wait holders
  handoffFinished <- getMonotonicTimeNSec
  completed <- readIORef completionOrder
  created <- readIORef connectionCount
  let handoffSeconds =
        fromIntegral (handoffFinished - handoffStarted) / 1.0e9 :: Double
      handoffThroughput = fromIntegral waiterCount / handoffSeconds :: Double
      fifoViolations = length $ filter id $
        zipWith (/=) completed [1 .. waiterCount]
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
