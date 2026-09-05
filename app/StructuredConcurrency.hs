module StructuredConcurrency
  ( ConcurrentFailure (..)
  , runConcurrentlyFailFast
  , withSubmittedSlots
  ) where

import           Control.Concurrent       (forkIO)
import           Control.Concurrent.Async (Async, AsyncCancelled, async, cancel,
                                           waitAnyCatch, waitCatch)
import           Control.Exception        (AsyncException, Exception,
                                           SomeException, fromException, mask,
                                           onException, throwIO, toException,
                                           try)
import           Control.Monad            (void)
import           Data.IORef               (atomicModifyIORef', newIORef,
                                           readIORef)
import           Data.Typeable            (Typeable)

-- | A worker body failure remains the primary error.  Failures raised by
-- cancelled siblings (for example, while closing their resources) are retained
-- rather than discarded and are available as secondary diagnostics.
data ConcurrentFailure = ConcurrentFailure
  { concurrentPrimaryFailure         :: SomeException
  , concurrentSiblingCleanupFailures :: [SomeException]
  } deriving (Typeable)

instance Show ConcurrentFailure where
  show (ConcurrentFailure primary cleanupFailures) =
    "concurrent worker failed: " ++ show primary
      ++ "; sibling cleanup failures: " ++ show cleanupFailures

instance Exception ConcurrentFailure

-- | Run workers as one cancellation scope.  A failing worker cancels and joins
-- every sibling before its exception is propagated to the caller.  The first
-- completed failing worker is primary; non-cancellation failures from sibling
-- cleanup are reported in 'ConcurrentFailure'.  If only one failure occurs,
-- its original exception type is rethrown.
runConcurrentlyFailFast :: [IO ()] -> IO ()
runConcurrentlyFailFast actions = mask $ \restore ->
  let
    spawn [] = pure []
    spawn (action : remaining) = do
      worker <- async (restore action)
      spawned <- try (spawn remaining)
      case spawned of
        Right workers -> pure (worker : workers)
        Left exception -> do
          cleanupFailures <- cancelAndCollect [worker]
          throwIO $ combineFailures exception cleanupFailures

    waitForWorkers [] = pure (Right ())
    waitForWorkers workers = do
      (completed, result) <- waitAnyCatch workers
      case result of
        Left exception -> do
          cleanupFailures <- cancelAndCollect (filter (/= completed) workers)
          pure $ Left $ combineFailures exception cleanupFailures
        Right () -> waitForWorkers (filter (/= completed) workers)
  in do
    workers <- spawn actions
    result <- try (restore (waitForWorkers workers))
    case result of
      Right (Right ()) -> pure ()
      Right (Left exception) -> throwIO exception
      Left exception -> do
        cleanupFailures <- cancelAndCollect workers
        throwIO $ combineFailures exception cleanupFailures

cancelAndCollect :: [Async ()] -> IO [SomeException]
cancelAndCollect workers = do
  mapM_ cancel workers
  results <- mapM waitCatch workers
  pure
    [ exception
    | Left exception <- results
    , not (isExpectedCancellation exception)
    ]

combineFailures :: SomeException -> [SomeException] -> SomeException
combineFailures primary [] = primary
combineFailures primary cleanupFailures =
  toException $ ConcurrentFailure primary cleanupFailures

isExpectedCancellation :: SomeException -> Bool
isExpectedCancellation exception =
  case fromException exception :: Maybe AsyncCancelled of
    Just _  -> True
    Nothing ->
      case fromException exception :: Maybe AsyncException of
        Just _  -> True
        Nothing -> False

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
