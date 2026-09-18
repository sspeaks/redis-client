{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Cluster-aware Redis command client with automatic slot routing and
-- redirection handling. Protocol adapters that need raw RESP frames should
-- depend on the cluster sublibrary's internal raw-command module instead.
module Database.Redis.Cluster.Client
  ( ClusterClient (..)
  , ClusterCommandClient
  , RedisClientError (..)
  , RedisClusterFailure (..)
  , RedisLifecycleFailure (..)
  , RedisProtocolFailure (..)
  , ClusterError
  , pattern MovedError
  , pattern AskError
  , pattern ClusterDownError
  , pattern TryAgainError
  , pattern CrossSlotError
  , pattern RedisCommandError
  , pattern MaxRetriesExceeded
  , pattern TopologyError
  , pattern ConnectionError
  , pattern ConnectionTimeoutError
  , pattern ClusterAuthenticationError
  , pattern ClusterClientClosed
  , ClusterConfig (..)
  , ClusterConfigException (..)
  , defaultClusterConfig
  , ClusterAuthentication (..)
  , ClusterAuthenticationException (..)
  , ClusterRuntimeAuthenticationUnsupported (..)
  , createClusterClient
  , createClusterClientWithAuthentication
  , createClusterClientWithBoundedConnector
  , createClusterClientWithFactories
  , closeClusterClient
  , withClusterClient
  , withClusterClientAuthentication
  , refreshTopology
  , runClusterCommandClient
  , executeKeyedClusterCommand
  , executeKeyedClusterCommandUsingDelay
  , executeKeylessClusterCommand
  , executeKeylessClusterCommandUsingDelay
  , module RedisCommandClient
  , RedirectionInfo (..)
  , RetryRoute (..)
  , classifyClusterReply
  , parseRedirectionError
  , detectRedirection
  , withRetryAndRefreshUsing
  ) where

import           Database.Redis.Cluster.Internal.ClientImplementation
import qualified Database.Redis.Command                               as RedisCommandClient
