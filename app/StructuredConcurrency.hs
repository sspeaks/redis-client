module StructuredConcurrency
  ( runConcurrentlyFailFast
  ) where

import           Control.Concurrent.Async (Async, async, cancel, waitAnyCatch,
                                           waitCatch)
import           Control.Exception        (SomeException, mask, onException,
                                           throwIO)

-- | Run workers as one cancellation scope.  A failing worker cancels and joins
-- every sibling before its exception is propagated to the caller.
runConcurrentlyFailFast :: [IO ()] -> IO ()
runConcurrentlyFailFast actions = mask $ \restore ->
  let
    spawn [] = pure []
    spawn (action : remaining) = do
      worker <- async (restore action)
      (worker :) <$> spawn remaining `onException` cancelAndWait [worker]

    waitForWorkers [] = pure ()
    waitForWorkers workers = do
      (completed, result) <- waitAnyCatch workers
      case result of
        Left exception -> do
          cancelAndWait workers
          throwIO (exception :: SomeException)
        Right () -> waitForWorkers (filter (/= completed) workers)
  in do
    workers <- spawn actions
    restore (waitForWorkers workers) `onException` cancelAndWait workers

cancelAndWait :: [Async ()] -> IO ()
cancelAndWait workers = do
  mapM_ cancel workers
  mapM_ waitCatch workers
