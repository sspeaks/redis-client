{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString                 as BS
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommand)
import           GHC.Clock                       (getMonotonicTimeNSec)
import           System.Environment              (getArgs)
import           Text.Printf                     (printf)

data Scenario = Scenario
    { scenarioName      :: String
    , scenarioCommand   :: BS.ByteString
    , scenarioArguments :: [BS.ByteString]
    , scenarioExpected  :: ExpectedRouting
    }

data ExpectedRouting
    = ExpectedKeyless
    | ExpectedKey BS.ByteString
    | ExpectedCrossSlot

scenarios :: [Scenario]
scenarios =
    [ Scenario "keyless" "PING" [] ExpectedKeyless
    , Scenario "fixed-key" "GET" ["{route}:fixed"] (ExpectedKey "{route}:fixed")
    , Scenario
        "movable-key"
        "EVAL"
        ["return redis.call('GET', KEYS[1])", "1", "{route}:movable"]
        (ExpectedKey "{route}:movable")
    , Scenario
        "same-slot-multi-key"
        "MGET"
        ["{route}:one", "{route}:two", "{route}:three"]
        (ExpectedKey "{route}:one")
    , Scenario
        "rejected-cross-slot"
        "MGET"
        ["{route-a}:one", "{route-b}:two"]
        ExpectedCrossSlot
    ]

main :: IO ()
main = do
    args <- getArgs
    let iterations =
            case args of
                [iterationText] -> read iterationText
                _               -> 1000000
    started <- getMonotonicTimeNSec
    checksum <- loop iterations 0
    finished <- getMonotonicTimeNSec
    let operations = iterations * length scenarios
        seconds = fromIntegral (finished - started) / 1.0e9 :: Double
    printf
        "iterations=%d scenarios=%d operations=%d checksum=%d elapsed_s=%.6f throughput_ops_s=%.2f\n"
        iterations
        (length scenarios)
        operations
        checksum
        seconds
        (fromIntegral operations / seconds :: Double)

loop :: Int -> Int -> IO Int
loop !remaining !checksum
    | remaining <= 0 = pure checksum
    | otherwise = do
        nextChecksum <- foldScenarios scenarios checksum
        loop (remaining - 1) nextChecksum

foldScenarios :: [Scenario] -> Int -> IO Int
foldScenarios [] !checksum = pure checksum
foldScenarios (scenario : remaining) !checksum = do
    contribution <- runScenario scenario
    foldScenarios remaining (checksum + contribution)

runScenario :: Scenario -> IO Int
runScenario scenario =
    case (scenarioExpected scenario, classifyCommand (scenarioCommand scenario) (scenarioArguments scenario)) of
        (ExpectedKeyless, KeylessRoute) -> pure 1
        (ExpectedKey expected, KeyedRoute actual)
            | actual == expected -> pure (BS.length actual)
        (ExpectedCrossSlot, CommandError message)
            | message == "CROSSSLOT Keys in request don't hash to the same slot" ->
                pure (length message)
        (_, actual) ->
            fail $
                "scenario " <> scenarioName scenario
                    <> " produced unexpected routing: "
                    <> renderRouting actual

renderRouting :: CommandRouting -> String
renderRouting KeylessRoute       = "KeylessRoute"
renderRouting (KeyedRoute key)   = "KeyedRoute " <> show key
renderRouting (CommandError err) = "CommandError " <> show err
