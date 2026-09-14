module FillLimits
  ( FillConcurrencyPlan (..)
  , effectiveFillConnections
  , fillConcurrencyPlan
  , clusterFillConcurrencyPlan
  , formatMemoryEstimate
  ) where

import           AppConfig   (RunState (..))
import           Data.Maybe  (fromMaybe)
import           Text.Printf (printf)

data FillConcurrencyPlan = FillConcurrencyPlan
  { plannedProcesses     :: Int
  , plannedConnections   :: Int
  , plannedWorkerCount   :: Integer
  , estimatedMemoryBytes :: Integer
  } deriving (Eq, Show)

maxProcesses, maxConnections :: Int
maxProcesses = 8
maxConnections = 16

maxWorkers, maxEstimatedMemoryBytes, randomNoiseBytes :: Integer
maxWorkers = 32
maxEstimatedMemoryBytes = 2 * 1024 * 1024 * 1024
randomNoiseBytes = 128 * 1024 * 1024

fillConcurrencyPlan :: RunState -> Either String FillConcurrencyPlan
fillConcurrencyPlan state =
  buildPlan state 1

clusterFillConcurrencyPlan :: Int -> RunState -> Either String FillConcurrencyPlan
clusterFillConcurrencyPlan masterCount state
  | masterCount < 1 = Left "Cluster fill requires at least one primary node"
  | otherwise = buildPlan state masterCount

effectiveFillConnections :: RunState -> Int
effectiveFillConnections state
  | serial state = 1
  | otherwise = fromMaybe 2 (numConnections state)

buildPlan :: RunState -> Int -> Either String FillConcurrencyPlan
buildPlan state masterCount = do
  processes <- positive "Process count" $ fromMaybe 1 (numProcesses state)
  configuredConnections <- positive "Connection count" $ fromMaybe 2 (numConnections state)
  pipeline <- positive "Pipeline batch size" $ pipelineBatchSize state
  keyBytes <- positive "Key size" $ keySize state
  valueBytes <- positive "Value size" $ valueSize state
  let connections = effectiveFillConnections state
      workersPerProcess = connections
      workers = toInteger processes * toInteger masterCount * toInteger workersPerProcess
      bytesPerCommand = toInteger keyBytes + toInteger valueBytes + 64
      pipelineBytes = toInteger pipeline * bytesPerCommand
      estimate = toInteger processes * randomNoiseBytes + workers * pipelineBytes
      plan = FillConcurrencyPlan processes connections workers estimate
      overrideHint = "; reduce --processes, --connections, or --pipeline, or explicitly pass --allow-high-scale-fill"
  if allowHighScaleFill state
    then Right plan
    else do
      if processes > maxProcesses
        then Left $ "Process count must not exceed " ++ show maxProcesses ++ overrideHint
        else Right ()
      if configuredConnections > maxConnections
        then Left $ "Connection count must not exceed " ++ show maxConnections ++ overrideHint
        else Right ()
      if workers > maxWorkers
        then Left $ "Total fill workers must not exceed " ++ show maxWorkers ++ overrideHint
        else Right ()
      if estimate > maxEstimatedMemoryBytes
        then Left $
          "Estimated peak client memory is " ++ formatMemoryEstimate estimate
            ++ ", exceeding the " ++ formatMemoryEstimate maxEstimatedMemoryBytes
            ++ " safety limit" ++ overrideHint
        else Right plan

positive :: String -> Int -> Either String Int
positive label value
  | value < 1 = Left $ label ++ " must be at least 1"
  | otherwise = Right value

formatMemoryEstimate :: Integer -> String
formatMemoryEstimate bytes =
  printf "%.2f MiB" (fromIntegral bytes / (1024 * 1024) :: Double)
