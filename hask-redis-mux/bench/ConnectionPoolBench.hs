{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

module Main (main) where

import           Control.Concurrent                    (getNumCapabilities,
                                                        setNumCapabilities)
import           Control.Concurrent.Async              (mapConcurrently)
import           Control.Monad                         (replicateM)
import           Data.IORef                            (atomicModifyIORef',
                                                        newIORef)
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
  let workers = max 1 (capabilities * 8)
      operationsPerWorker = 2000
      totalOperations = workers * operationsPerWorker
      config = PoolConfig 1 5 0 False
      address = NodeAddress "benchmark" 6379
  pool <- createPool config
  connectionCount <- newIORef (0 :: Int)
  let connector _ = do
        atomicModifyIORef' connectionCount $ \count -> (count + 1, ())
        return BenchConnected
      oneOperation = do
        started <- getMonotonicTimeNSec
        withConnection pool address connector $ \_ -> return ()
        finished <- getMonotonicTimeNSec
        return (finished - started)
  started <- getMonotonicTimeNSec
  samples <- fmap concat $ mapConcurrently
    (\_ -> replicateM operationsPerWorker oneOperation)
    [1 .. workers]
  finished <- getMonotonicTimeNSec
  let sorted = sort samples
      percentile p =
        sorted !! min (length sorted - 1) ((length sorted * p) `div` 100)
      seconds = fromIntegral (finished - started) / 1.0e9 :: Double
      throughput = fromIntegral totalOperations / seconds :: Double
  printf
    "caps=%d workers=%d operations=%d throughput_ops_s=%.2f p95_us=%.2f p99_us=%.2f\n"
    capabilities
    workers
    totalOperations
    throughput
    (fromIntegral (percentile 95) / 1000 :: Double)
    (fromIntegral (percentile 99) / 1000 :: Double)
  closePool pool
