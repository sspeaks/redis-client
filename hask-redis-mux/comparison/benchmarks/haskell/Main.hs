{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Data.ByteString.Char8     as BS
import           Data.IORef
import           Data.List                 (sort)
import           Database.Redis
import           Database.Redis.Standalone (withStandaloneClient)
import           System.Clock
import           System.Environment        (getArgs)
import           System.IO                 (hFlush, hPutStrLn, stderr)
import           Text.Printf               (hPrintf, printf)

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
        []    -> "localhost:6379"
      (host, port) = parseConnString connStr

  hPrintf stderr "Connecting to %s:%d\n" host port
  hFlush stderr

  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress host port
        , standaloneConnector       = clusterPlaintextConnector
        , standaloneMultiplexerCount = 1
        }

  withStandaloneClient config $ \client -> do
    let run :: StandaloneCommandClient a -> IO a
        run = runStandaloneClient client

    hPutStrLn stderr "Starting benchmarks..."
    hFlush stderr

    putStrLn "{"

    -- PING benchmark
    benchmark "ping" 10000 (run (ping :: StandaloneCommandClient ByteString) >> return ())
    putStrLn ","

    -- SET benchmark
    benchmark "set" 10000 (run (set "bench:key" "bench:value" :: StandaloneCommandClient Bool) >> return ())
    putStrLn ","

    -- GET benchmark
    _ <- run (set "bench:key" "bench:value" :: StandaloneCommandClient Bool)
    benchmark "get" 10000 (run (get "bench:key" :: StandaloneCommandClient ByteString) >> return ())
    putStrLn ","

    -- DEL benchmark
    benchmark "del" 10000 (do
      _ <- run (set "bench:delkey" "v" :: StandaloneCommandClient Bool)
      _ <- run (del ["bench:delkey"] :: StandaloneCommandClient Integer)
      return ()
      )
    putStrLn ","

    -- Pipeline benchmark (sequential gets via multiplexer auto-pipelining)
    do
      mapM_ (\i -> run (set (BS.pack $ "bench:pipe:" <> show i) (BS.pack $ "val" <> show i) :: StandaloneCommandClient Bool)) [1..100 :: Int]
      benchmark "pipeline_100_gets" 1000 (do
        mapM_ (\i -> run (get (BS.pack $ "bench:pipe:" <> show i) :: StandaloneCommandClient ByteString)) [1..100 :: Int]
        )
    putStrLn ","

    -- MGET benchmarks for batch sizes
    do
      mapM_ (\i -> run (set (BS.pack $ "bench:mget:" <> show i) (BS.pack $ "val" <> show i) :: StandaloneCommandClient Bool)) [1..1000 :: Int]

      let mgetKeys n = map (\i -> BS.pack $ "bench:mget:" <> show i) [1..n :: Int]

      benchmark "mget_10" 5000 (run (mget (mgetKeys 10) :: StandaloneCommandClient [ByteString]) >> return ())
      putStrLn ","

      benchmark "mget_100" 2000 (run (mget (mgetKeys 100) :: StandaloneCommandClient [ByteString]) >> return ())
      putStrLn ","

      benchmark "mget_1000" 500 (run (mget (mgetKeys 1000) :: StandaloneCommandClient [ByteString]) >> return ())
    putStrLn ","

    -- MSET equivalent (sequential sets, auto-pipelined)
    do
      let msetBatch n = mapM_ (\i -> run (set (BS.pack $ "bench:mset:" <> show i) (BS.pack $ "val" <> show i) :: StandaloneCommandClient Bool)) [1..n :: Int]

      benchmark "mset_equiv_10" 5000 (msetBatch (10 :: Int))
      putStrLn ","

      benchmark "mset_equiv_100" 2000 (msetBatch (100 :: Int))
      putStrLn ","

      benchmark "mset_equiv_1000" 500 (msetBatch (1000 :: Int))

    putStrLn ""
    putStrLn "}"

    -- Cleanup
    _ <- run (del ["bench:key", "bench:delkey"] :: StandaloneCommandClient Integer)
    mapM_ (\i -> run (del [BS.pack $ "bench:pipe:" <> show i] :: StandaloneCommandClient Integer)) [1..100 :: Int]
    mapM_ (\i -> run (del [BS.pack $ "bench:mget:" <> show i] :: StandaloneCommandClient Integer)) [1..1000 :: Int]
    mapM_ (\i -> run (del [BS.pack $ "bench:mset:" <> show i] :: StandaloneCommandClient Integer)) [1..1000 :: Int]

    hPutStrLn stderr "Benchmarks complete. Use +RTS -s for memory/GC stats."
    hFlush stderr
