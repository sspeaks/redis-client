{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString                 as BS
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommand)
import           GHC.Clock                       (getMonotonicTimeNSec)
import           System.Environment              (getArgs)
import           Text.Printf                     (printf)

main :: IO ()
main = do
    args <- getArgs
    let (workload, itemCount, iterations) =
            case args of
                [countText, iterationText] -> ("xread", read countText, read iterationText)
                [workloadText, countText, iterationText] ->
                    (workloadText, read countText, read iterationText)
                _ -> ("xread", 1024, 1000)
        (command, arguments) = workloadFrame workload itemCount
    started <- getMonotonicTimeNSec
    checksum <- loop command iterations arguments 0
    finished <- getMonotonicTimeNSec
    let seconds = fromIntegral (finished - started) / 1.0e9 :: Double
    printf
        "workload=%s items=%d iterations=%d checksum=%d elapsed_s=%.6f throughput_ops_s=%.2f\n"
        workload
        itemCount
        iterations
        checksum
        seconds
        (fromIntegral iterations / seconds :: Double)

workloadFrame :: String -> Int -> (BS.ByteString, [BS.ByteString])
workloadFrame workload itemCount =
    case workload of
        "mget" -> ("MGET", replicate itemCount "{profile}:key")
        "del" -> ("DEL", replicate itemCount "{profile}:key")
        "sadd" -> ("SADD", "{profile}:key" : replicate itemCount "member")
        "xread" ->
            let streams = ["{profile}:" <> decimal index | index <- [1 .. itemCount]]
             in ("XREAD", ["COUNT", "1", "BLOCK", "0", "STREAMS"] <> streams <> replicate itemCount "0-0")
        _ -> error "workload must be one of: xread, mget, del, sadd"

loop :: BS.ByteString -> Int -> [BS.ByteString] -> Int -> IO Int
loop command remaining arguments checksum
    | remaining <= 0 = pure checksum
    | otherwise =
        case classifyCommand command arguments of
            KeyedRoute key ->
                loop command (remaining - 1) arguments (checksum + BS.length key)
            KeylessRoute -> fail "expected a keyed route"
            CommandError message -> fail message

decimal :: Int -> BS.ByteString
decimal = BS.pack . fmap (fromIntegral . fromEnum) . show
