{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Cluster-aware Redis command client with automatic slot routing and
-- redirection handling. Protocol adapters that forward client RESP frames use
-- 'forwardClusterFrame'.
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
  , forwardClusterFrame
  , clusterMasterAddresses
  , connectClusterNode
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
