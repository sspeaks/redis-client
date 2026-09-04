{-# LANGUAGE ScopedTypeVariables #-}

module LibraryE2E.NodeLifecycle
  ( NodeTarget (..)
  , NodeCommand (..)
  , NodeCommandFailure (..)
  , NodeReadinessFailure (..)
  , NodeLifecycleException (..)
  , NodeLifecycleOps (..)
  , ProcessRunner
  , runNodeCommandUsing
  , sanitizeDiagnostic
  , waitForReadinessUsing
  , withStoppedNodeUsing
  , withStoppedNodesUsing
  ) where

import           Control.Concurrent (threadDelay)
import           Control.Exception  (Exception, IOException, SomeAsyncException,
                                     SomeException, displayException,
                                     fromException, mask, throwIO, try)
import           Control.Monad      (forM)
import           Data.Char          (isPrint, toLower)
import           Data.IORef         (newIORef, readIORef, writeIORef)
import           Data.List          (find, isInfixOf)
import           System.Exit        (ExitCode (..))
import           System.IO          (hPutStrLn, stderr)
import           System.Timeout     (timeout)

data NodeTarget = NodeTarget
  { nodeNumber    :: Int
  , nodeContainer :: String
  , targetHost    :: String
  , targetPort    :: Int
  } deriving (Eq, Show)

data NodeCommand = StopNode | StartNode
  deriving (Eq, Show)

data NodeCommandFailure = NodeCommandFailure
  { failedNodeCommand :: NodeCommand
  , failedNodeTarget  :: NodeTarget
  , failedExitCode    :: Maybe ExitCode
  , failedStdout      :: String
  , failedStderr      :: String
  }

instance Show NodeCommandFailure where
  show failure = unlines
    [ show (failedNodeCommand failure) ++ " failed for "
        ++ renderTarget (failedNodeTarget failure)
    , "exit: " ++ maybe "process launch failure" show
        (failedExitCode failure)
    , "stdout: " ++ failedStdout failure
    , "stderr: " ++ failedStderr failure
    ]

instance Exception NodeCommandFailure

data NodeReadinessFailure = NodeReadinessFailure
  { readinessNode        :: NodeTarget
  , readinessWaitSeconds :: Int
  , readinessDiagnostic  :: String
  }

instance Show NodeReadinessFailure where
  show failure = unlines
    [ "Redis node did not rejoin the healthy cluster: "
        ++ renderTarget (readinessNode failure)
    , "waited seconds: " ++ show (readinessWaitSeconds failure)
    , "last diagnostic: " ++ readinessDiagnostic failure
    ]

instance Exception NodeReadinessFailure

data NodeLifecycleException
  = NodeCleanupFailed [SomeException]
  | NodeBodyAndCleanupFailed SomeException [SomeException]

instance Show NodeLifecycleException where
  show (NodeCleanupFailed cleanupFailures) =
    "Redis node cleanup failed:\n"
      ++ renderExceptions cleanupFailures
  show (NodeBodyAndCleanupFailed primary cleanupFailures) =
    "Redis node test body failed: "
      ++ safeExceptionText primary
      ++ "\nRedis node cleanup also failed:\n"
      ++ renderExceptions cleanupFailures

instance Exception NodeLifecycleException

data NodeLifecycleOps = NodeLifecycleOps
  { stopNodeOperation  :: NodeTarget -> IO ()
  , startNodeOperation :: NodeTarget -> IO ()
  , waitNodeReady      :: NodeTarget -> IO ()
  }

type ProcessRunner =
  FilePath -> [String] -> String -> IO (ExitCode, String, String)

runNodeCommandUsing
  :: ProcessRunner
  -> NodeCommand
  -> NodeTarget
  -> IO ()
runNodeCommandUsing runner command target = do
  result <- try $ runner "docker" [commandName command, nodeContainer target] ""
  case result of
    Left (err :: IOException) ->
      throwIO $ NodeCommandFailure
        command
        target
        Nothing
        ""
        (sanitizeDiagnostic $ displayException err)
    Right (ExitSuccess, _, _) -> return ()
    Right (exitCode, stdoutOutput, stderrOutput) ->
      throwIO $ NodeCommandFailure
        command
        target
        (Just exitCode)
        (sanitizeDiagnostic stdoutOutput)
        (sanitizeDiagnostic stderrOutput)

waitForReadinessUsing
  :: Int
  -> (NodeTarget -> IO ())
  -> NodeTarget
  -> IO ()
waitForReadinessUsing maxWaitSeconds probe target = do
  lastDiagnostic <- newIORef "readiness probe did not complete"
  result <- timeout (waitSeconds * 1000000) $ poll lastDiagnostic
  case result of
    Just () -> return ()
    Nothing -> do
      diagnostic <- readIORef lastDiagnostic
      throwIO $ NodeReadinessFailure target waitSeconds diagnostic
  where
    waitSeconds = max 1 maxWaitSeconds

    poll lastDiagnostic = do
      result <- tryAny $ probe target
      case result of
        Right () -> return ()
        Left err ->
          case fromException err :: Maybe SomeAsyncException of
            Just async -> throwIO async
            Nothing -> do
              writeIORef lastDiagnostic $
                sanitizeDiagnostic $ displayException err
              threadDelay 500000
              poll lastDiagnostic

withStoppedNodeUsing
  :: NodeLifecycleOps
  -> NodeTarget
  -> IO a
  -> IO a
withStoppedNodeUsing operations target =
  withStoppedNodesUsing operations [target]

withStoppedNodesUsing
  :: NodeLifecycleOps
  -> [NodeTarget]
  -> IO a
  -> IO a
withStoppedNodesUsing operations targets action =
  mask $ \restore -> do
    stopped <- stopTargets [] targets
    case stopped of
      Left (primary, attemptedTargets) -> do
        cleanupFailures <- restoreTargets attemptedTargets
        resolveResult (Left primary) cleanupFailures
      Right stoppedTargets -> do
        bodyResult <- tryAny $ restore action
        cleanupFailures <- restoreTargets stoppedTargets
        resolveResult bodyResult cleanupFailures
  where
    stopTargets attempted [] = return $ Right attempted
    stopTargets attempted (target : remaining) = do
      result <- tryAny $ stopNodeOperation operations target
      let attemptedTargets = attempted ++ [target]
      case result of
        Left err -> return $ Left (err, attemptedTargets)
        Right () -> stopTargets attemptedTargets remaining

    restoreTargets attemptedTargets = do
      startResults <- forM attemptedTargets $ \target ->
        tryAny $ startNodeOperation operations target
      readinessResults <- forM attemptedTargets $ \target ->
        tryAny $ waitNodeReady operations target
      return $ failures startResults ++ failures readinessResults

resolveResult
  :: Either SomeException a
  -> [SomeException]
  -> IO a
resolveResult (Right value) [] = return value
resolveResult (Right _) cleanupFailures =
  case firstAsyncException cleanupFailures of
    Just async -> do
      reportCleanupFailures cleanupFailures
      throwIO async
    Nothing ->
      throwIO $ NodeCleanupFailed cleanupFailures
resolveResult (Left primary) [] = throwIO primary
resolveResult (Left primary) cleanupFailures =
  case fromException primary :: Maybe SomeAsyncException of
    Just async -> do
      reportCleanupFailures cleanupFailures
      throwIO async
    Nothing ->
      case firstAsyncException cleanupFailures of
        Just async -> do
          reportPrimaryAndCleanupFailures primary cleanupFailures
          throwIO async
        Nothing ->
          throwIO $ NodeBodyAndCleanupFailed primary cleanupFailures

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

failures :: [Either SomeException ()] -> [SomeException]
failures = foldr collect []
  where
    collect (Left err) rest = err : rest
    collect (Right ()) rest = rest

firstAsyncException :: [SomeException] -> Maybe SomeAsyncException
firstAsyncException cleanupFailures =
  findAsync =<< find hasAsync cleanupFailures
  where
    hasAsync err =
      case fromException err :: Maybe SomeAsyncException of
        Just _  -> True
        Nothing -> False
    findAsync err = fromException err

reportCleanupFailures :: [SomeException] -> IO ()
reportCleanupFailures cleanupFailures = do
  _ <- tryAny $ hPutStrLn stderr $
    "Redis node cleanup failed while preserving asynchronous cancellation:\n"
      ++ renderExceptions cleanupFailures
  return ()

reportPrimaryAndCleanupFailures
  :: SomeException
  -> [SomeException]
  -> IO ()
reportPrimaryAndCleanupFailures primary cleanupFailures = do
  _ <- tryAny $ hPutStrLn stderr $
    "Redis node test body failed before asynchronous cancellation: "
      ++ safeExceptionText primary
      ++ "\nRedis node cleanup also failed:\n"
      ++ renderExceptions cleanupFailures
  return ()

renderExceptions :: [SomeException] -> String
renderExceptions =
  unlines . map (("  - " ++) . safeExceptionText)

safeExceptionText :: SomeException -> String
safeExceptionText = sanitizeDiagnostic . displayException

sanitizeDiagnostic :: String -> String
sanitizeDiagnostic raw
  | any (`isInfixOf` lowered) sensitiveMarkers =
      "<redacted sensitive diagnostic>"
  | otherwise =
      take 2000 $ map sanitizeCharacter raw
  where
    lowered = map toLower raw
    sensitiveMarkers =
      [ "password"
      , "passwd"
      , "secret"
      , "credential"
      , "rediscli_auth"
      , "authorization"
      , "token="
      ]
    sanitizeCharacter character
      | character == '\n' || character == '\t' = character
      | isPrint character = character
      | otherwise = '?'

commandName :: NodeCommand -> String
commandName StopNode  = "stop"
commandName StartNode = "start"

renderTarget :: NodeTarget -> String
renderTarget target =
  nodeContainer target
    ++ " (node " ++ show (nodeNumber target)
    ++ ", " ++ targetHost target
    ++ ":" ++ show (targetPort target) ++ ")"
