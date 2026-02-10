{-# LANGUAGE OverloadedStrings #-}

-- | Shared utilities for end-to-end tests
module E2EHelpers
  ( getRedisClientPath
  , cleanupProcess
  , waitForSubstring
  , drainHandle
  ) where

import Control.Exception (IOException, evaluate, try)
import Control.Monad     (void)
import Data.List         (isInfixOf)
import System.Directory  (doesFileExist, findExecutable)
import System.Environment (getExecutablePath)
import System.Exit       (ExitCode (..))
import System.FilePath   (takeDirectory, (</>))
import System.IO         (Handle, hGetContents, hGetLine)
import System.Process    (ProcessHandle, terminateProcess, waitForProcess)

-- | Locate the redis-client executable, searching sibling directory first then PATH
getRedisClientPath :: IO FilePath
getRedisClientPath = do
  execPath <- getExecutablePath
  let binDir = takeDirectory execPath
      sibling = binDir </> "redis-client"
  siblingExists <- doesFileExist sibling
  if siblingExists
    then return sibling
    else do
      found <- findExecutable "redis-client"
      case found of
        Just path -> return path
        Nothing -> error $ "Could not locate redis-client executable starting from " <> binDir

-- | Terminate and wait for a process, ignoring errors
cleanupProcess :: ProcessHandle -> IO ()
cleanupProcess ph = do
  _ <- (try (terminateProcess ph) :: IO (Either IOException ()))
  _ <- (try (waitForProcess ph) :: IO (Either IOException ExitCode))
  pure ()

-- | Block until a specific substring appears in handle output
waitForSubstring :: Handle -> String -> IO ()
waitForSubstring handle needle = do
  line <- hGetLine handle
  if needle `isInfixOf` line
    then pure ()
    else waitForSubstring handle needle

-- | Read all remaining content from a handle
drainHandle :: Handle -> IO String
drainHandle handle = do
  result <- try (hGetContents handle) :: IO (Either IOException String)
  case result of
    Left _ -> pure ""
    Right contents -> do
      void $ evaluate (length contents)
      pure contents
