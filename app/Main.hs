{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (receive, send), TLSClient (..), serve)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class
import Control.Monad.State qualified as State
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as BS
import Filler (fillCacheWithData)
import RedisCommandClient
import Resp (Encodable (encode), RespData (RespArray, RespBulkString))
import System.Console.GetOpt (ArgDescr (..), ArgOrder (..), OptDescr (Option), getOpt, usageInfo)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, stdout)
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
    (_, _, errs) -> ioError (userError (concat errs ++ usageInfo "Usage: redis-client [mode] [OPTION...]" options))

main :: IO ()
main = do
  (mode : args) <- getArgs
  (state, _) <- handleArgs args
  unless (mode `elem` ["cli", "fill", "tunn"]) $ do
    printf "Invalid mode '%s' specified\nValid modes are 'cli', 'fill', and 'tunn'\n" mode
    putStrLn $ usageInfo "Usage: redis-client [mode] [OPTION...]" options
    exitFailure
  when (null (host state)) $ do
    putStrLn "No host specified\n"
    putStrLn $ usageInfo "Usage: redis-client [OPTION...]" options
    exitFailure
  when (mode == "tunn") $ tunn state
  when (mode == "cli") $ cli state
  when (mode == "fill") $ fill state

tunn :: RunState -> IO ()
tunn state = do
  putStrLn "Starting tunnel mode"
  if useTLS state
    then runCommandsAgainstTLSHost state $ do
      ClientState !client _ <- State.get
      serve (TLSTunnel client)
    else do
      -- starts a server socket that listens on localhost and passes the traffic to the redis client
      putStrLn "Tunnel mode is only supported with TLS enabled\n"
      exitFailure
  exitSuccess

fill :: RunState -> IO ()
fill state = do
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
    exitSuccess
  exitFailure

cli :: RunState -> IO ()
cli state = do
  putStrLn "Starting CLI mode"
  if useTLS state
    then runCommandsAgainstTLSHost state repl
    else runCommandsAgainstPlaintextHost state repl
  exitSuccess

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
