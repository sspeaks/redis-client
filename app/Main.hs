{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (void, when, unless)
import Filler (fillCacheWithData)
import RedisCommandClient
import System.Console.GetOpt (ArgDescr (..), ArgOrder (..), OptDescr (Option), getOpt, usageInfo)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import Text.Printf (printf)
import Client (Client (send))
import Control.Monad.IO.Class
import Resp (RespData (RespArray, RespBulkString), Encodable (encode))
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Control.Monad.State as State
import qualified Data.ByteString.Builder as Builder
import Client (Client(receive))
import System.IO (stdout, hFlush)

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
    (_, _, errs) -> ioError (userError (concat errs ++ usageInfo "Usage: redis-client [mode] [OPTION...]" options))

main :: IO ()
main = do
  (mode:args) <- getArgs
  (state, _) <- handleArgs args
  unless (mode `elem` ["cli", "fill"]) $ do
    printf "Invalid mode '%s' specified\nValid modes are 'cli' and 'fill'\n" mode
    putStrLn $ usageInfo "Usage: redis-client [mode] [OPTION...]" options
    exitFailure
  when (mode == "cli") $ do
    putStrLn "Starting CLI mode\n"
    if useTLS state
      then runCommandsAgainstTLSHost state repl
      else runCommandsAgainstPlaintextHost state repl
    exitSuccess
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

repl :: (Client client) => RedisCommandClient client ()
repl = do
  ClientState !client _ <- State.get
  loop client
  where
    loop !client = do
      liftIO $ putStr "> " >> hFlush stdout
      command <- liftIO getLine
      unless (command == "exit") $ do
        (send client . Builder.toLazyByteString . encode . RespArray . map (RespBulkString . BS.pack)) . words $ command
        response <- parseWith (receive client)
        liftIO $ print response
        loop client
