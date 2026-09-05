module StructuredConcurrency
  ( runConcurrentlyFailFast
  , withSubmittedSlots
  ) where

import           Control.Concurrent       (forkIO)
import           Control.Concurrent.Async (Async, async, cancel, waitAnyCatch,
                                           waitCatch)
import           Control.Exception        (SomeException, mask, onException,
                                           throwIO)
import           Control.Monad            (void)
import           Data.IORef               (atomicModifyIORef', newIORef,
                                           readIORef)

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

-- | Scope asynchronous submissions.  A slot remains in the scope until its
-- wait starts; if the scope exits first, a cleanup worker owns that wait.
-- The wait action must provide its own narrow interruptible region.
withSubmittedSlots
  :: Eq slot
  => (slot -> IO a)
  -> ((IO slot -> IO slot) -> (slot -> IO a) -> IO b)
  -> IO b
withSubmittedSlots await action = mask $ \_ -> do
  owned <- newIORef []
  let cleanup = readIORef owned >>= mapM_ (void . forkIO . void . await)
      submit acquire = do
        slot <- acquire
        atomicModifyIORef' owned (\slots -> (slot : slots, ()))
        return slot
      waitSubmitted slot = do
        atomicModifyIORef' owned (\slots -> (filter (/= slot) slots, ()))
        await slot
  action submit waitSubmitted `onException` cleanup
