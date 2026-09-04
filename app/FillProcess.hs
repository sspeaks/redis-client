module FillProcess
  ( buildChildArgs
  ) where

import           AppConfig (RunState (..))

buildChildArgs :: RunState -> Int -> Int -> [String]
buildChildArgs state idx dataGB =
  [ "fill"
  , "-h", host state
  , "-d", show dataGB
  , "--process-index", show idx
  , "--key-size", show (keySize state)
  , "--value-size", show (valueSize state)
  , "--pipeline", show (pipelineBatchSize state)
  ]
  ++ (["-t" | useTLS state])
  ++ (["--allow-insecure-plaintext-auth" | allowInsecurePlaintextAuth state])
  ++ (["-c" | useCluster state])
  ++ (["-s" | serial state])
  ++ (case port state of
        Just p  -> ["-p", show p]
        Nothing -> [])
  ++ (if username state /= "default" then ["-u", username state] else [])
  ++ (case numConnections state of
        Just n  -> ["-n", show n]
        Nothing -> [])
