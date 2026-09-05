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
    let (streamCount, iterations) =
            case args of
                [countText, iterationText] -> (read countText, read iterationText)
                _ -> (1024, 1000)
        streams = ["{profile}:" <> decimal index | index <- [1 .. streamCount]]
        arguments = ["COUNT", "1", "BLOCK", "0", "STREAMS"] <> streams <> replicate streamCount "0-0"
    started <- getMonotonicTimeNSec
    checksum <- loop iterations arguments 0
    finished <- getMonotonicTimeNSec
    let seconds = fromIntegral (finished - started) / 1.0e9 :: Double
    printf
        "streams=%d iterations=%d checksum=%d elapsed_s=%.6f throughput_ops_s=%.2f\n"
        streamCount
        iterations
        checksum
        seconds
        (fromIntegral iterations / seconds :: Double)

loop :: Int -> [BS.ByteString] -> Int -> IO Int
loop remaining arguments checksum
    | remaining <= 0 = pure checksum
    | otherwise =
        case classifyCommand "XREAD" arguments of
            KeyedRoute key -> loop (remaining - 1) arguments (checksum + BS.length key)
            KeylessRoute -> fail "expected a keyed XREAD route"
            CommandError message -> fail message

decimal :: Int -> BS.ByteString
decimal = BS.pack . fmap (fromIntegral . fromEnum) . show
