module Database.Redis.Client.ConnectionSetup
  ( withSetupResource
  ) where

import           Control.Exception (mask, onException)

-- | Acquire a setup resource under interruptible masking and release it if any
-- later setup phase fails or is cancelled before ownership transfer.
withSetupResource :: IO resource -> (resource -> IO ()) -> (resource -> IO result) -> IO result
withSetupResource acquire release use = mask $ \restore -> do
  resource <- acquire
  restore (use resource) `onException` release resource
