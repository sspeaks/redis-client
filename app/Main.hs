{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (receive, send),
                                             TLSClient (..), serve)
import           Control.Concurrent         (forkIO, newEmptyMVar, putMVar,
                                             takeMVar)
import           Control.Monad              (unless, void, when)
import           Control.Monad.IO.Class
import qualified Control.Monad.State.Strict as State
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Lazy.Char8 as BS
import           Data.Word                  (Word64)
import           Filler                     (fillCacheWithData,
                                             fillCacheWithDataMB,
                                             initRandomNoise)
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommandClient,
                                             RedisCommands (flushAll),
                                             RunState (..), parseWith,
                                             runCommandsAgainstPlaintextHost,
                                             runCommandsAgainstTLSHost)
import           Resp                       (Encodable (encode),
                                             RespData (RespArray, RespBulkString))
import           System.Console.GetOpt      (ArgDescr (..), ArgOrder (..),
                                             OptDescr (Option), getOpt,
                                             usageInfo)
import           System.Console.Readline    (addHistory, readline)
import           System.Environment         (getArgs)
import           System.Exit                (exitFailure, exitSuccess)
import           System.IO                  (hIsTerminalDevice, isEOF, stdin)
import           System.Random              (randomIO)
import           Text.Printf                (printf)

defaultRunState :: RunState
defaultRunState = RunState "" Nothing "default" "" False 0 False False (Just 2)

options :: [OptDescr (RunState -> IO RunState)]
options =
  [ Option ['h'] ["host"] (ReqArg (\arg opt -> return $ opt {host = arg}) "HOST") "Host to connect to",
    Option ['p'] ["port"] (ReqArg (\arg opt -> return $ opt {port = Just . read $ arg}) "PORT") "Port to connect to. Will default to 6379 for plaintext and 6380 for TLS",
    Option ['u'] ["username"] (ReqArg (\arg opt -> return $ opt {username = arg}) "USERNAME") "Username to authenticate with (default: 'default')",
    Option ['a'] ["password"] (ReqArg (\arg opt -> return $ opt {password = arg}) "PASSWORD") "Password to authenticate with",
    Option ['t'] ["tls"] (NoArg (\opt -> return $ opt {useTLS = True})) "Use TLS",
    Option ['d'] ["data"] (ReqArg (\arg opt -> return $ opt {dataGBs = read arg}) "GBs") "Random data amount to send in GB",
    Option ['f'] ["flush"] (NoArg (\opt -> return $ opt {flush = True})) "Flush the database",
    Option ['s'] ["serial"] (NoArg (\opt -> return $ opt {serial = True})) "Run in serial mode (no concurrency)",
    Option ['n'] ["connections"] (ReqArg (\arg opt -> return $ opt {numConnections = Just . read $ arg}) "NUM") "Number of parallel connections (default: 2)"
  ]

handleArgs :: [String] -> IO (RunState, [String])
handleArgs args = do
  case getOpt Permute options args of
    (o, n, []) -> (,n) <$> foldl (>>=) (return defaultRunState) o
    (_, _, errs) -> ioError (userError (concat errs ++ usageInfo "Usage: redis-client [mode] [OPTION...]" options))

main :: IO ()
main = do
  args' <- getArgs
  case args' of
    [] -> do
      putStrLn $ usageInfo "Usage: redis-client [mode] [OPTION...]" options
      putStrLn ""
      putStrLn "Modes:"
      putStrLn "  cli     Interactive Redis command-line interface"
      putStrLn "  fill    Fill Redis cache with random data for testing"
      putStrLn "  tunn    Start TLS tunnel proxy (requires -t flag)"
      putStrLn ""
      putStrLn "Environment Variables for Performance Tuning:"
      putStrLn "  REDIS_CLIENT_FILL_CHUNK_KB    Chunk size in KB (default: 8192)"
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  redis-client fill -h localhost -d 5                    # Fill 5GB with defaults"
      putStrLn "  REDIS_CLIENT_FILL_CHUNK_KB=4096 redis-client fill ...  # Use 4MB chunks"
      exitFailure
    (mode : args) -> do
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
    initRandomNoise -- Ensure noise buffer is initialized once and shared
    baseSeed <- randomIO :: IO Word64
    if serial state
      then do
        printf "Filling cache '%s' with %dGB of data using serial mode\n" (host state) (dataGBs state)
        if useTLS state
          then runCommandsAgainstTLSHost state $ fillCacheWithData baseSeed 0 (dataGBs state)
          else runCommandsAgainstPlaintextHost state $ fillCacheWithData baseSeed 0 (dataGBs state)
      else do
        -- Use numConnections (defaults to 8)
        let nConns = maybe 8 id (numConnections state)
            totalMB = dataGBs state * 1024  -- Work in MB for finer granularity
            baseMB = totalMB `div` nConns
            remainder = totalMB `mod` nConns
            -- Each connection gets (baseMB + 1) or baseMB MB
            -- Jobs: (connectionIdx, mbForThisConnection)
            jobs = [(i, if i < remainder then baseMB + 1 else baseMB) | i <- [0..nConns - 1], baseMB > 0 || i < remainder]
        printf "Filling cache '%s' with %dGB of data using %d parallel connections\n" (host state) (dataGBs state) (length jobs)
        mvars <- mapM (\(idx, mb) -> do
            mv <- newEmptyMVar
            _ <- forkIO $ do
                 if useTLS state
                    then runCommandsAgainstTLSHost state $ fillCacheWithDataMB baseSeed idx mb
                    else runCommandsAgainstPlaintextHost state $ fillCacheWithDataMB baseSeed idx mb
                 putMVar mv ()
            return mv) jobs
        mapM_ takeMVar mvars
    exitSuccess
  exitFailure

cli :: RunState -> IO ()
cli state = do
  putStrLn "Starting CLI mode"
  isTTY <- hIsTerminalDevice stdin
  if useTLS state
    then runCommandsAgainstTLSHost state (repl isTTY)
    else runCommandsAgainstPlaintextHost state (repl isTTY)
  exitSuccess

repl :: (Client client) => Bool -> RedisCommandClient client ()
repl isTTY = do
  ClientState !client _ <- State.get
  loop client
  where
    loop !client = do
      command <- liftIO readCommand
      case command of
        Nothing -> return ()
        Just cmd -> do
          when isTTY $ liftIO $ addHistory cmd
          unless (cmd == "exit") $ do
            (send client . Builder.toLazyByteString . encode . RespArray . map (RespBulkString . BS.pack)) . words $ cmd
            response <- parseWith (receive client)
            liftIO $ print response
            loop client
    readCommand
      | isTTY = readline "> "
      | otherwise = do
          eof <- isEOF
          if eof
            then return Nothing
            else Just <$> getLine
