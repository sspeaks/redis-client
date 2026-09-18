{-# LANGUAGE DeriveDataTypeable #-}

-- | Unified public errors returned by Redis command runners.
--
-- Synchronous exceptions caught at a public runner boundary are retained as
-- 'SomeException' causes. Asynchronous exceptions are never converted to
-- 'Left'; 'tryRedisClient' rethrows them so cancellation remains effective.
module Database.Redis.RedisError
  ( RedisClientError (..)
  , RedisProtocolFailure (..)
  , RedisClusterFailure (..)
  , RedisLifecycleFailure (..)
  , tryRedisClient
  ) where

import           Control.Exception   (Exception, SomeAsyncException,
                                      SomeException, displayException,
                                      fromException, throwIO, try)
import           Data.ByteString     (ByteString)
import           Data.Typeable       (Typeable, typeOf)
import           Data.Word           (Word16)
import           Database.Redis.Resp (RespData)

-- | One root error type for all public command runners.
data RedisClientError
  = RedisServerError !ByteString
  | RedisConversionError !RespData
  | RedisProtocolError !RedisProtocolFailure
  | RedisTransportError !SomeException
  | RedisClusterError !RedisClusterFailure
  | RedisLifecycleError !RedisLifecycleFailure
  deriving Typeable

-- | RESP framing and connection-stream failures.
data RedisProtocolFailure
  = RedisParseFailure !String
  | RedisConnectionClosed
  | RedisCommandValidationFailure !String
  deriving (Eq, Show, Typeable)

-- | Cluster routing, redirect, retry, and topology failures.
data RedisClusterFailure
  = RedisMoved !Word16 !String !Int
  | RedisAsk !Word16 !String !Int
  | RedisClusterDown !ByteString
  | RedisTryAgain !ByteString
  | RedisCrossSlot !ByteString
  | RedisRetryExhausted !Int !RedisClientError
  | RedisTopologyFailure !String
  deriving (Eq, Show, Typeable)

-- | Client construction, shutdown, and unsupported lifecycle operations.
data RedisLifecycleFailure
  = RedisClientClosed
  | RedisSetupFailure !SomeException
  | RedisCleanupFailure !SomeException
  | RedisActionCleanupFailure !RedisClientError !SomeException
  | RedisUnsupportedOperation !SomeException
  | RedisUncertainWrite !SomeException !SomeException
  deriving Typeable

instance Show RedisClientError where
  show (RedisServerError message) = "Redis server error: " ++ show message
  show (RedisConversionError response) =
    "Unexpected Redis response: " ++ show response
  show (RedisProtocolError failure) = show failure
  show (RedisTransportError cause) =
    "Redis transport failure: " ++ displayException cause
  show (RedisClusterError failure) = show failure
  show (RedisLifecycleError failure) = show failure

instance Show RedisLifecycleFailure where
  show RedisClientClosed = "Redis client is closed"
  show (RedisSetupFailure cause) =
    "Redis client setup failed: " ++ displayException cause
  show (RedisCleanupFailure cause) =
    "Redis client cleanup failed: " ++ displayException cause
  show (RedisActionCleanupFailure primary cleanup) =
    show primary ++ "; Redis client cleanup also failed: "
      ++ displayException cleanup
  show (RedisUnsupportedOperation cause) =
    "Unsupported Redis client operation: " ++ displayException cause
  show (RedisUncertainWrite primary cleanup) =
    "Redis write outcome is uncertain: " ++ displayException primary
      ++ "; cleanup also failed: " ++ displayException cleanup

instance Eq RedisClientError where
  RedisServerError left == RedisServerError right = left == right
  RedisConversionError left == RedisConversionError right = left == right
  RedisProtocolError left == RedisProtocolError right = left == right
  RedisTransportError left == RedisTransportError right =
    sameException left right
  RedisClusterError left == RedisClusterError right = left == right
  RedisLifecycleError left == RedisLifecycleError right = left == right
  _ == _ = False

instance Eq RedisLifecycleFailure where
  RedisClientClosed == RedisClientClosed = True
  RedisSetupFailure left == RedisSetupFailure right = sameException left right
  RedisCleanupFailure left == RedisCleanupFailure right =
    sameException left right
  RedisActionCleanupFailure leftPrimary leftCleanup
    == RedisActionCleanupFailure rightPrimary rightCleanup =
      leftPrimary == rightPrimary && sameException leftCleanup rightCleanup
  RedisUnsupportedOperation left == RedisUnsupportedOperation right =
    sameException left right
  RedisUncertainWrite leftPrimary leftCleanup
    == RedisUncertainWrite rightPrimary rightCleanup =
      sameException leftPrimary rightPrimary
        && sameException leftCleanup rightCleanup
  _ == _ = False

sameException :: SomeException -> SomeException -> Bool
sameException left right =
  typeOf left == typeOf right
    && displayException left == displayException right

instance Exception RedisClientError

-- | Convert a synchronous exception to the public root error while preserving
-- an already-classified 'RedisClientError'. Cancellation is rethrown.
tryRedisClient :: IO a -> IO (Either RedisClientError a)
tryRedisClient action = do
  result <- try action
  case result of
    Right value -> pure $ Right value
    Left (exception :: SomeException) ->
      case fromException exception of
        Just async -> throwIO (async :: SomeAsyncException)
        Nothing ->
          case fromException exception of
            Just redisError -> pure $ Left redisError
            Nothing         -> pure $ Left $ RedisTransportError exception
