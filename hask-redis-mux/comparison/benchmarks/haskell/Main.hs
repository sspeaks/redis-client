{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Data.ByteString.Char8         as BS
import           Data.IORef
import           Data.List                     (sort)
import           Database.Redis
import           Database.Redis.Cluster.Client (withClusterClient)
import           System.Clock
import           System.Environment            (getArgs)
import           System.IO                     (hFlush, hPutStrLn, stderr)
import           Text.Printf                   (hPrintf, printf)

-- | Convert TimeSpec to microseconds
toMicroseconds :: TimeSpec -> Double
toMicroseconds ts = fromIntegral (sec ts) * 1e6 + fromIntegral (nsec ts) / 1000

-- | Measure a single operation, return elapsed microseconds
timeOp :: IO a -> IO Double
timeOp action = do
  start <- getTime Monotonic
  _ <- action
  end <- getTime Monotonic
  return $ toMicroseconds (diffTimeSpec end start)

-- | Compute percentiles from a sorted list of latencies
percentile :: [Double] -> Double -> Double
percentile sorted p =
  let n = length sorted
      idx = max 0 (min (n - 1) (floor (p / 100.0 * fromIntegral n :: Double)))
  in sorted !! idx

-- | Run an operation many times, collect latencies
benchmark :: String -> Int -> IO () -> IO ()
benchmark name iterations action = do
  hPrintf stderr "  Running %s (%d iterations)...\n" name iterations
  hFlush stderr

  latencies <- newIORef ([] :: [Double])

  -- Warm-up: 10% of iterations
  let warmup = max 10 (iterations `div` 10)
  mapM_ (\_ -> action) [1..warmup]

  -- Measured iterations
  mapM_ (\_ -> do
    elapsed <- timeOp action
    modifyIORef' latencies (elapsed :)
    ) [1..iterations]

  lats <- readIORef latencies
  let sorted = sort lats
      p50 = percentile sorted 50
      p95 = percentile sorted 95
      p99 = percentile sorted 99
      totalUs = sum sorted
      opsPerSec = fromIntegral iterations / (totalUs / 1e6) :: Double

  -- Output JSON fragment
  printf "    \"%s\": {\"p50_us\": %.1f, \"p95_us\": %.1f, \"p99_us\": %.1f, \"ops_per_sec\": %.0f, \"iterations\": %d}"
    name p50 p95 p99 opsPerSec iterations

-- | Parse host:port from a connection string
parseConnString :: String -> (String, Int)
parseConnString s =
  case break (== ':') s of
    (host, ':':portStr) -> (host, read portStr)
    (host, _)           -> (host, 6379)

main :: IO ()
main = do
  args <- getArgs
  let connStr = case args of
        (x:_) -> x
        []    -> "localhost:7000"
      (host, port) = parseConnString connStr

  hPrintf stderr "Connecting to cluster seed %s:%d\n" host port
  hFlush stderr

  let config = ClusterConfig
        { clusterSeedNode                = NodeAddress host port
        , clusterPoolConfig              = PoolConfig
            { maxConnectionsPerNode = 4
            , connectionTimeout     = 5000000
            , maxRetries            = 3
            , useTLS                = False
            }
        , clusterMaxRetries              = 3
        , clusterRetryDelay              = 100000
        , clusterTopologyRefreshInterval = 600
        }

  withClusterClient config clusterPlaintextConnector $ \client -> do
    let run :: ClusterCommandClient PlainTextClient a -> IO a
        run = runClusterCommandClient client

    hPutStrLn stderr "Starting cluster benchmarks..."
    hFlush stderr

    putStrLn "{"

    -- PING benchmark
    benchmark "ping" 10000 (run (ping :: ClusterCommandClient PlainTextClient ByteString) >> return ())
    putStrLn ","

    -- SET benchmark
    benchmark "set" 10000 (run (set "bench:key" "bench:value" :: ClusterCommandClient PlainTextClient Bool) >> return ())
    putStrLn ","

    -- GET benchmark
    _ <- run (set "bench:key" "bench:value" :: ClusterCommandClient PlainTextClient Bool)
    benchmark "get" 10000 (run (get "bench:key" :: ClusterCommandClient PlainTextClient ByteString) >> return ())
    putStrLn ","

    -- DEL benchmark
    benchmark "del" 10000 (do
      _ <- run (set "bench:delkey" "v" :: ClusterCommandClient PlainTextClient Bool)
      _ <- run (del ["bench:delkey"] :: ClusterCommandClient PlainTextClient Integer)
      return ()
      )
    putStrLn ","

    -- Pipeline benchmark (sequential gets via cluster routing)
    do
      mapM_ (\i -> run (set (BS.pack $ "bench:pipe:" <> show i) (BS.pack $ "val" <> show i) :: ClusterCommandClient PlainTextClient Bool)) [1..100 :: Int]
      benchmark "pipeline_100_gets" 1000 (do
        mapM_ (\i -> run (get (BS.pack $ "bench:pipe:" <> show i) :: ClusterCommandClient PlainTextClient ByteString)) [1..100 :: Int]
        )
    putStrLn ","

    -- Single-key GET benchmarks for batch sizes (MGET not usable cross-slot in cluster)
    do
      mapM_ (\i -> run (set (BS.pack $ "bench:mget:" <> show i) (BS.pack $ "val" <> show i) :: ClusterCommandClient PlainTextClient Bool)) [1..1000 :: Int]

      benchmark "get_10" 5000 (mapM_ (\i -> run (get (BS.pack $ "bench:mget:" <> show i) :: ClusterCommandClient PlainTextClient ByteString)) [1..10 :: Int])
      putStrLn ","

      benchmark "get_100" 2000 (mapM_ (\i -> run (get (BS.pack $ "bench:mget:" <> show i) :: ClusterCommandClient PlainTextClient ByteString)) [1..100 :: Int])
      putStrLn ","

      benchmark "get_1000" 500 (mapM_ (\i -> run (get (BS.pack $ "bench:mget:" <> show i) :: ClusterCommandClient PlainTextClient ByteString)) [1..1000 :: Int])
    putStrLn ","

    -- Sequential SET batches
    do
      let msetBatch n = mapM_ (\i -> run (set (BS.pack $ "bench:mset:" <> show i) (BS.pack $ "val" <> show i) :: ClusterCommandClient PlainTextClient Bool)) [1..n :: Int]

      benchmark "set_10" 5000 (msetBatch (10 :: Int))
      putStrLn ","

      benchmark "set_100" 2000 (msetBatch (100 :: Int))
      putStrLn ","

      benchmark "set_1000" 500 (msetBatch (1000 :: Int))

    putStrLn ""
    putStrLn "}"

    -- Cleanup (individual deletes to avoid CROSSSLOT errors)
    _ <- run (del ["bench:key"] :: ClusterCommandClient PlainTextClient Integer)
    _ <- run (del ["bench:delkey"] :: ClusterCommandClient PlainTextClient Integer)
    mapM_ (\i -> run (del [BS.pack $ "bench:pipe:" <> show i] :: ClusterCommandClient PlainTextClient Integer)) [1..100 :: Int]
    mapM_ (\i -> run (del [BS.pack $ "bench:mget:" <> show i] :: ClusterCommandClient PlainTextClient Integer)) [1..1000 :: Int]
    mapM_ (\i -> run (del [BS.pack $ "bench:mset:" <> show i] :: ClusterCommandClient PlainTextClient Integer)) [1..1000 :: Int]

    hPutStrLn stderr "Benchmarks complete. Use +RTS -s for memory/GC stats."
    hFlush stderr
