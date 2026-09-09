module ProcessLifecycle
  ( ChildProcessFailure (..)
  , waitForChildProcesses
  ) where

import           Control.Exception (Exception, throwIO)
import           Data.Typeable     (Typeable)
import           System.Exit       (ExitCode (ExitSuccess))
import           System.Process    (ProcessHandle, waitForProcess)

-- | A fill parent only reports completion after every child has exited.
-- The first non-success status in process-index order is propagated.
data ChildProcessFailure = ChildProcessFailure Int ExitCode
  deriving (Show, Typeable)

instance Exception ChildProcessFailure

waitForChildProcesses :: [ProcessHandle] -> IO ()
waitForChildProcesses handles = do
  exitCodes <- mapM waitForProcess handles
  case [ (index, exitCode)
       | (index, exitCode) <- zip [0..] exitCodes
       , exitCode /= ExitSuccess
       ] of
    []                      -> pure ()
    ((index, exitCode) : _) -> throwIO $ ChildProcessFailure index exitCode
