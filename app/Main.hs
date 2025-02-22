{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (void, when)
import Filler (fillCacheWithData)
import RedisCommandClient
import System.Console.GetOpt (ArgDescr (..), ArgOrder (..), OptDescr (Option), getOpt, usageInfo)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Printf (printf)

defaultRunState :: RunState
defaultRunState = RunState "" "" False 0 False

options :: [OptDescr (RunState -> IO RunState)]
options =
  [ Option ['h'] ["host"] (ReqArg (\arg opt -> return $ opt {host = arg}) "HOST") "Host to connect to",
    Option ['p'] ["password"] (ReqArg (\arg opt -> return $ opt {password = arg}) "PASSWORD") "Password to authenticate with",
    Option ['t'] ["tls"] (NoArg (\opt -> return $ opt {useTLS = True})) "Use TLS",
    Option ['d'] ["data"] (ReqArg (\arg opt -> return $ opt {dataGBs = read arg}) "GBs") "Random data amount to send in GB",
    Option ['f'] ["flush"] (NoArg (\opt -> return $ opt {flush = True})) "Flush the database"
  ]

handleArgs :: [String] -> IO (RunState, [String])
handleArgs args = do
  case getOpt Permute options args of
    (o, n, []) -> (,n) <$> foldl (>>=) (return defaultRunState) o
    (_, _, errs) -> ioError (userError (concat errs ++ usageInfo "Usage: redis-client [OPTION...]" options))

main :: IO ()
main =
  getArgs >>= handleArgs >>= \(state, _) -> do
    when (null (host state)) $ do
      putStrLn "No host specified\n"
      putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
      exitFailure
    when (dataGBs state <= 0 && not (flush state)) $ do
      putStrLn "No data specified or data is 0GB or fewer\n"
      putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
      exitFailure
    when (flush state) $ do
      printf "Flushing cache '%s'\n" (host state)
      if useTLS state
        then runCommandsAgainstTLSHost state (void flushAll)
        else runCommandsAgainstPlaintextHost state (void flushAll)
    when (dataGBs state > 0) $ do
      printf "Filling cache '%s' with %dGB of data\n" (host state) (dataGBs state)

      if useTLS state
        then runCommandsAgainstTLSHost state $ fillCacheWithData (dataGBs state)
        else runCommandsAgainstPlaintextHost state $ fillCacheWithData (dataGBs state)