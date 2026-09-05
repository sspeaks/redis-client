{-# LANGUAGE DataKinds #-}

-- | Cluster-aware Redis command client with automatic slot routing and
-- redirection handling. Protocol adapters that need raw RESP frames should
-- depend on the cluster sublibrary's internal raw-command module instead.
module Database.Redis.Cluster.Client
  ( ClusterClient (..)
  , ClusterCommandClient
  , ClusterError (..)
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
