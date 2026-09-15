{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

module Main (main) where

import           Control.Concurrent.Async            (async, cancel, waitCatch)
import           Control.Concurrent.MVar             (MVar, newEmptyMVar,
                                                      putMVar, takeMVar)
import           Control.Monad                       (forM, forM_, replicateM,
                                                      void)
import           Control.Monad.IO.Class              (liftIO)
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString.Builder             as Builder
import qualified Data.ByteString.Char8               as BS8
import qualified Data.ByteString.Lazy                as LBS
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
import           System.Mem                          (performGC)
import           Text.Printf                         (printf)

data BenchClient (a :: ConnectionStatus) where
  BenchConnected :: !(MVar ByteString) -> BenchClient 'Connected

instance Client BenchClient where
  connect = error "BenchClient: connect is not used"
  close _ = return ()
  send _ _ = return ()
  receive (BenchConnected responses) = liftIO $ takeMVar responses

main :: IO ()
main = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then fail "Run with +RTS -T -RTS to collect residency metrics"
    else do
      putStrLn "source=SlotPoolBurstBench cap=256"
      forM_ [64, 1024, 4096] $ runBurst 256
      runCancellation 256 1024

runBurst :: Int -> Int -> IO ()
runBurst cap concurrency = do
  pool <- createSlotPool cap
  responses <- newEmptyMVar
  mux <- createMultiplexer (BenchConnected responses) (receive $ BenchConnected responses)
  before <- getRTSStats
  started <- getMonotonicTimeNSec
  slots <- replicateM concurrency $ submitCommandAsync pool mux ping
  putMVar responses $ mconcat $ replicate concurrency okResponse
  latencies <- forM slots $ \slot -> do
    waitStarted <- getMonotonicTimeNSec
    _ <- waitSlot pool slot
    waitEnded <- getMonotonicTimeNSec
    return $ waitEnded - waitStarted
  finished <- getMonotonicTimeNSec
  performGC
  after <- getRTSStats
  retained <- slotPoolRetainedSlots pool
  printMetrics "burst" cap concurrency retained before after started finished latencies
  destroyMultiplexer mux

runCancellation :: Int -> Int -> IO ()
runCancellation cap concurrency = do
  pool <- createSlotPool cap
  responses <- newEmptyMVar
  mux <- createMultiplexer (BenchConnected responses) (receive $ BenchConnected responses)
  before <- getRTSStats
  started <- getMonotonicTimeNSec
  slots <- replicateM concurrency $ submitCommandAsync pool mux ping
  waiters <- mapM (async . waitSlot pool) (take 64 slots)
  mapM_ cancel waiters
  mapM_ (void . waitCatch) waiters
  destroyMultiplexer mux
  finished <- getMonotonicTimeNSec
  performGC
  after <- getRTSStats
  retained <- slotPoolRetainedSlots pool
  printMetrics "cancellation" cap concurrency retained before after started finished []

ping :: Builder.Builder
ping = Builder.stringUtf8 "*1\r\n$4\r\nPING\r\n"

okResponse :: ByteString
okResponse = LBS.toStrict $ Builder.toLazyByteString $ encode (RespSimpleString $ BS8.pack "OK")

printMetrics
  :: String
  -> Int
  -> Int
  -> Int
  -> RTSStats
  -> RTSStats
  -> Word64
  -> Word64
  -> [Word64]
  -> IO ()
printMetrics kind cap concurrency retained before after started finished latencies =
  printf
    "kind=%s concurrency=%d cap=%d retained=%d allocated_bytes=%d peak_residency_bytes=%d post_gc_live_bytes=%d throughput_ops_s=%.2f tail_p99_us=%.2f\n"
    kind concurrency cap retained allocated peak postGc throughput tailLatency
  where
    allocated = allocated_bytes after - allocated_bytes before
    peak = max_mem_in_use_bytes after
    postGc = gcdetails_live_bytes $ gc after
    elapsed = fromIntegral (finished - started) / 1.0e9 :: Double
    throughput = fromIntegral concurrency / elapsed
    tailLatency = percentile 99 latencies / 1000

percentile :: Int -> [Word64] -> Double
percentile _ [] = 0
percentile p values =
  fromIntegral $ sorted !! min (length sorted - 1) ((length sorted * p) `div` 100)
  where
    sorted = sort values
