{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent                  (threadDelay)
import           Control.Concurrent.Async            (async, mapConcurrently,
                                                      wait)
import           Control.Concurrent.STM              (TQueue, atomically,
                                                      newTQueueIO, readTQueue,
                                                      writeTQueue)
import           Control.Monad                       (replicateM_, when)
import           Control.Monad.IO.Class              (liftIO)
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString                     as BS
import qualified Data.ByteString.Builder             as Builder
import qualified Data.ByteString.Lazy                as LBS
import           Data.IORef                          (IORef, atomicModifyIORef',
                                                      newIORef, readIORef)
import           Data.List                           (sort)
import           Data.Word                           (Word64)
import           Database.Redis.Client               (Client (..),
                                                      ConnectionStatus (..))
import           Database.Redis.Internal.Multiplexer
import           Database.Redis.Resp                 (Encodable (encode),
                                                      RespData (RespSimpleString))
import           GHC.Clock                           (getMonotonicTimeNSec)
import           GHC.Stats                           (GCDetails (..),
                                                      RTSStats (..),
                                                      getRTSStats,
                                                      getRTSStatsEnabled)
import           System.Environment                  (getArgs)
import           System.Mem                          (performGC)
import           Text.Printf                         (printf)

data BenchClient (a :: ConnectionStatus) where
  BenchConnected
    :: !(IORef [Int])
    -> !(IORef Int)
    -> !(IORef Int)
    -> !(TQueue ByteString)
    -> BenchClient 'Connected

instance Client BenchClient where
  connect = error "BenchClient: connect is not used"
  close _ = return ()
  send (BenchConnected batchSizes sendCount maxBatch _) lbs =
    liftIO $ do
      let commandCount = batchCommandCount (LBS.toStrict lbs)
      atomicModifyIORef' batchSizes $ \sizes -> (sizes ++ [commandCount], ())
      atomicModifyIORef' sendCount $ \count -> (count + 1, ())
      atomicModifyIORef' maxBatch $ \current -> (max current commandCount, ())
  receive (BenchConnected _ _ _ replies) = liftIO $ atomically $ readTQueue replies

data BenchMode = Baseline | Bounded
  deriving (Eq, Show)

main :: IO ()
main = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then fail "Run with +RTS -T -RTS to collect residency metrics"
    else do
      mode <- parseMode =<< getArgs
      runBench mode

runBench :: BenchMode -> IO ()
runBench mode = do
  let totalCommands = 8192
      payloadBytes = 4096
      initialStallUs = 200000
      burstSize = 32
      burstDelayUs = 2000
      config =
        case mode of
          Baseline -> MultiplexerConfig totalCommands totalCommands
          Bounded  -> defaultMultiplexerConfig
  pool <- createSlotPool 256
  batchSizes <- newIORef []
  sendCount <- newIORef 0
  maxBatch <- newIORef 0
  replies <- newTQueueIO
  let client = BenchConnected batchSizes sendCount maxBatch replies
  mux <- createMultiplexerWithConfig config client (receive client)
  before <- getRTSStats
  started <- getMonotonicTimeNSec
  responder <- async $ do
    threadDelay initialStallUs
    replicateM_ (totalCommands `div` burstSize) $ do
      atomically $ writeTQueue replies $ mconcat $ replicate burstSize okResponse
      threadDelay burstDelayUs
  let runProducer index = do
        startedAt <- getMonotonicTimeNSec
        _ <- submitCommandPooled pool mux (setCommand payloadBytes index)
        finishedAt <- getMonotonicTimeNSec
        return (finishedAt - startedAt)
  latencies <- mapConcurrently runProducer [1 .. totalCommands]
  wait responder
  finished <- getMonotonicTimeNSec
  stats <- readMultiplexerStats mux
  sendBatches <- readIORef batchSizes
  totalSends <- readIORef sendCount
  observedMaxBatch <- readIORef maxBatch
  destroyMultiplexer mux
  performGC
  after <- getRTSStats
  printf
    "mode=%s total_commands=%d payload_bytes=%d admission_limit=%d writer_batch_limit=%d peak_outstanding=%d send_batches=%d max_batch_commands=%d allocated_bytes=%d peak_residency_bytes=%d post_gc_live_bytes=%d mutator_cpu_s=%.3f gc_cpu_s=%.3f total_cpu_s=%.3f throughput_ops_s=%.2f latency_p50_us=%.2f latency_p95_us=%.2f latency_p99_us=%.2f\n"
    (show mode)
    totalCommands
    payloadBytes
    (muxStatsAdmissionLimit stats)
    (muxStatsWriterBatchLimit stats)
    (muxStatsPeakOutstanding stats)
    totalSends
    observedMaxBatch
    (allocated_bytes after - allocated_bytes before)
    (max_mem_in_use_bytes after)
    (gcdetails_live_bytes $ gc after)
    (nsToSeconds (mutator_cpu_ns after - mutator_cpu_ns before))
    (nsToSeconds (gc_cpu_ns after - gc_cpu_ns before))
    (nsToSeconds (cpu_ns after - cpu_ns before))
    (throughput totalCommands started finished)
    (percentile 50 latencies)
    (percentile 95 latencies)
    (percentile 99 latencies)
  whenBounded mode stats observedMaxBatch sendBatches

whenBounded :: BenchMode -> MultiplexerStats -> Int -> [Int] -> IO ()
whenBounded mode stats observedMaxBatch sendBatches =
  case mode of
    Baseline -> do
      when (null sendBatches) $
        fail "baseline benchmark produced no writer batches"
    Bounded -> do
      when (muxStatsPeakOutstanding stats > muxStatsAdmissionLimit stats) $
        fail "bounded benchmark exceeded the configured admission limit"
      when (observedMaxBatch > muxStatsWriterBatchLimit stats) $
        fail "bounded benchmark exceeded the configured writer batch limit"

parseMode :: [String] -> IO BenchMode
parseMode ["baseline"] = return Baseline
parseMode ["bounded"] = return Bounded
parseMode _ =
  fail "usage: cabal run MultiplexerBackpressureBench -- baseline|bounded +RTS -T -RTS"

setCommand :: Int -> Int -> Builder.Builder
setCommand payloadBytes index =
  encodeCommand
    [ "SET"
    , key
    , value
    ]
  where
    key =
      LBS.toStrict $
        Builder.toLazyByteString (Builder.stringUtf8 "bench:" <> Builder.intDec index)
    value = BS.replicate payloadBytes valueByte
    valueByte = fromIntegral ((index `mod` 251) + 1)

encodeCommand :: [ByteString] -> Builder.Builder
encodeCommand args =
  Builder.byteString ("*" <> bshow (length args) <> "\r\n")
    <> foldMap
      (\arg ->
        Builder.byteString
          ("$" <> bshow (BS.length arg) <> "\r\n" <> arg <> "\r\n"))
      args
  where
    bshow value =
      LBS.toStrict (Builder.toLazyByteString (Builder.intDec value))

okResponse :: ByteString
okResponse =
  LBS.toStrict $ Builder.toLazyByteString $ encode (RespSimpleString "OK")

batchCommandCount :: ByteString -> Int
batchCommandCount = countSubstrings "*3\r\n$3\r\nSET\r\n"

countSubstrings :: ByteString -> ByteString -> Int
countSubstrings needle haystack
  | BS.null needle = 0
  | otherwise = go 0 haystack
  where
    go !count remaining =
      case BS.breakSubstring needle remaining of
        (_, rest)
          | BS.null rest -> count
          | otherwise ->
              go (count + 1) (BS.drop (BS.length needle) rest)

throughput :: Int -> Word64 -> Word64 -> Double
throughput operations started finished =
  fromIntegral operations / (fromIntegral (finished - started) / 1.0e9 :: Double)

nsToSeconds :: Integral a => a -> Double
nsToSeconds = (/ 1.0e9) . fromIntegral

percentile :: Int -> [Word64] -> Double
percentile _ [] = 0
percentile p values =
  fromIntegral (sorted !! min (length sorted - 1) ((length sorted * p) `div` 100))
    / 1000
  where
    sorted = sort values
