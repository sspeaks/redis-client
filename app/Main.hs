{-# LANGUAGE OverloadedStrings #-}

module Main where

import Client (Client (..))
import Control.Monad (replicateM, replicateM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State qualified as State
import Data.ByteString (ByteString)
import Data.ByteString qualified as BSC
import Data.List (isInfixOf)
import Data.Maybe (fromJust, isJust)
import Data.Time.Clock.POSIX (getPOSIXTime)
import RedisCommandClient
import Resp (RespData (..), encode, parseManyWith)
import System.Console.GetOpt (ArgDescr (..), ArgOrder (..), OptDescr (Option), getOpt, usageInfo)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Random.Stateful
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

fillCacheWithData :: (Client client) => Int -> RedisCommandClient client ()
fillCacheWithData gb = do
  client <- State.get
  seed <- liftIO $ round <$> getPOSIXTime
  gen <- newIOGenM (mkStdGen seed)
  replicateM_ (4 * gb) $ do
    setPipe <- mconcat <$> replicateM numToPipeline (genRandomSet gen)
    send client setPipe
    result <- foldr (\x acc -> if isJust acc then acc else isError x) Nothing <$> parseManyWith numToPipeline (recieve client)
    when (isJust result) $ do
      error $ printf "Error: %s\n" (fromJust result)
    keys <- extractInt <$> dbsize
    liftIO $ printf "+256MB - Keys (1KB) now in database: %d\n" (keys :: Integer)
  liftIO $ printf "Finished filling cache with %dGB of data\n" gb
  where
    extractInt (RespInteger i) = i
    extractInt _ = error "Expected RespInteger"
    isError (RespError e) = Just e
    isError _ = Nothing

randomBytes :: (StatefulGen g m) => g -> m ByteString
randomBytes = uniformByteStringM 512

genRandomSet :: (StatefulGen g m) => g -> m ByteString
genRandomSet gen = do
  key <- randomBytes gen
  value <- randomBytes gen
  return $ encode . RespArray $ map RespBulkString ["SET", key, value]

numToPipeline :: Int
numToPipeline = 1024 * 256

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