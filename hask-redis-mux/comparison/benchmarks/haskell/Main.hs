{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent            (getNumCapabilities)
import           Control.Concurrent.Async      (forConcurrently_)
import           Control.Monad                 (replicateM, void)
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

-- | Build a key from a prefix and index, distributing across cluster slots
mkKey :: BS.ByteString -> Int -> BS.ByteString
mkKey prefix i = prefix <> BS.pack (show i)

-- | Run an operation concurrently across threads, collect latencies.
-- The action receives a globally unique iteration index for key generation.
-- Throughput is measured from wall-clock time; latency from per-op timing.
benchmark :: String -> Int -> Int -> (Int -> IO ()) -> IO ()
benchmark name iterations numThreads action = do
  let perThread = iterations `div` numThreads
      warmupPerThread = max 10 (perThread `div` 10)
      stride = warmupPerThread + perThread
  hPrintf stderr "  Running %s (%d iterations, %d threads)...\n" name (perThread * numThreads) numThreads
  hFlush stderr

  latencyRefs <- replicateM numThreads (newIORef ([] :: [Double]))

  -- Warm-up (concurrent)
  forConcurrently_ [0..numThreads-1] $ \tIdx -> do
    let base = tIdx * stride
    mapM_ (\i -> action (base + i)) [0..warmupPerThread-1]

  -- Measured (concurrent, timed by wall clock)
  wallStart <- getTime Monotonic
  forConcurrently_ (zip [0..numThreads-1] latencyRefs) $ \(tIdx, ref) -> do
    let base = tIdx * stride + warmupPerThread
    mapM_ (\i -> do
      elapsed <- timeOp (action (base + i))
      modifyIORef' ref (elapsed :)
      ) [0..perThread-1]
  wallEnd <- getTime Monotonic

  allLats <- concat <$> mapM readIORef latencyRefs
  let sorted = sort allLats
      actualIters = length sorted
      p50 = percentile sorted 50
      p95 = percentile sorted 95
      p99 = percentile sorted 99
      wallTimeUs = toMicroseconds (diffTimeSpec wallEnd wallStart)
      opsPerSec = fromIntegral actualIters / (wallTimeUs / 1e6) :: Double

  -- Output JSON fragment
  printf "    \"%s\": {\"p50_us\": %.1f, \"p95_us\": %.1f, \"p99_us\": %.1f, \"ops_per_sec\": %.0f, \"iterations\": %d}"
    name p50 p95 p99 opsPerSec actualIters

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

  numThreads <- getNumCapabilities
  hPrintf stderr "Using %d threads (from +RTS -N)\n" numThreads
  hFlush stderr

  withClusterClient config clusterPlaintextConnector $ \client -> do
    let run :: ClusterCommandClient PlainTextClient a -> IO a
        run = runClusterCommandClient client

    hPutStrLn stderr "Starting cluster benchmarks..."
    hFlush stderr

    putStrLn "{"

    -- PING via cluster client (same abstraction as SET/GET/DEL)
    benchmark "ping" 10000 numThreads $ \_i ->
      void $ run (ping :: ClusterCommandClient PlainTextClient ByteString)
    putStrLn ","

    -- SET with distributed keys
    benchmark "set" 10000 numThreads $ \i ->
      void $ run (set (mkKey "bench:set:" i) "bench:value" :: ClusterCommandClient PlainTextClient Bool)
    putStrLn ","

    -- Pre-populate a shared key pool for all read benchmarks
    let readKeyPool = 10000 :: Int
    hPutStrLn stderr "  Pre-populating read key pool..."
    hFlush stderr
    forConcurrently_ [0..numThreads-1] $ \t -> do
      let chunk = readKeyPool `div` numThreads
          lo = t * chunk
          hi = if t == numThreads - 1 then readKeyPool - 1 else (t + 1) * chunk - 1
      mapM_ (\i -> void $ run (set (mkKey "bench:r:" i) (BS.pack $ "val" <> show i) :: ClusterCommandClient PlainTextClient Bool)) [lo..hi]

    -- GET with distributed keys from pool
    benchmark "get" 10000 numThreads $ \i ->
      void $ run (get (mkKey "bench:r:" (i `mod` readKeyPool)) :: ClusterCommandClient PlainTextClient ByteString)
    putStrLn ","

    -- DEL with unique keys per iteration
    benchmark "del" 10000 numThreads $ \i -> do
      let key = mkKey "bench:del:" i
      void $ run (set key "v" :: ClusterCommandClient PlainTextClient Bool)
      void $ run (del [key] :: ClusterCommandClient PlainTextClient Integer)
    putStrLn ","

    -- Sequential 100 gets - each GET waits for response before sending next
    benchmark "sequential_100_gets" 1000 numThreads $ \i ->
      mapM_ (\j -> void $ run (get (mkKey "bench:r:" ((i * 100 + j) `mod` readKeyPool)) :: ClusterCommandClient PlainTextClient ByteString)) [0..99 :: Int]
    putStrLn ","

    -- GET batch benchmarks (keys from pool distribute across all slots)
    benchmark "get_10" 5000 numThreads $ \i ->
      mapM_ (\j -> void $ run (get (mkKey "bench:r:" ((i * 10 + j) `mod` readKeyPool)) :: ClusterCommandClient PlainTextClient ByteString)) [0..9 :: Int]
    putStrLn ","

    benchmark "get_100" 2000 numThreads $ \i ->
      mapM_ (\j -> void $ run (get (mkKey "bench:r:" ((i * 100 + j) `mod` readKeyPool)) :: ClusterCommandClient PlainTextClient ByteString)) [0..99 :: Int]
    putStrLn ","

    benchmark "get_1000" 500 numThreads $ \i ->
      mapM_ (\j -> void $ run (get (mkKey "bench:r:" ((i * 1000 + j) `mod` readKeyPool)) :: ClusterCommandClient PlainTextClient ByteString)) [0..999 :: Int]
    putStrLn ","

    -- SET batch benchmarks with distributed keys
    benchmark "set_10" 5000 numThreads $ \i ->
      mapM_ (\j -> void $ run (set (mkKey "bench:mset:" (i * 10 + j)) (BS.pack $ "val" <> show j) :: ClusterCommandClient PlainTextClient Bool)) [0..9 :: Int]
    putStrLn ","

    benchmark "set_100" 2000 numThreads $ \i ->
      mapM_ (\j -> void $ run (set (mkKey "bench:mset:" (i * 100 + j)) (BS.pack $ "val" <> show j) :: ClusterCommandClient PlainTextClient Bool)) [0..99 :: Int]
    putStrLn ","

    benchmark "set_1000" 500 numThreads $ \i ->
      mapM_ (\j -> void $ run (set (mkKey "bench:mset:" (i * 1000 + j)) (BS.pack $ "val" <> show j) :: ClusterCommandClient PlainTextClient Bool)) [0..999 :: Int]

    putStrLn ""
    putStrLn "}"

    -- Cleanup pre-populated key pool
    hPutStrLn stderr "Cleaning up benchmark keys..."
    hFlush stderr
    forConcurrently_ [0..numThreads-1] $ \t -> do
      let chunk = readKeyPool `div` numThreads
          lo = t * chunk
          hi = if t == numThreads - 1 then readKeyPool - 1 else (t + 1) * chunk - 1
      mapM_ (\i -> void $ run (del [mkKey "bench:r:" i] :: ClusterCommandClient PlainTextClient Integer)) [lo..hi]

    hPutStrLn stderr "Benchmarks complete. Use +RTS -s for memory/GC stats."
    hFlush stderr
