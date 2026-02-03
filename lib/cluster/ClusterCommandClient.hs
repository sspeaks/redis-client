{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ClusterCommandClient
  ( ClusterClient (..),
    ClusterError (..),
    RedirectionInfo (..),
    ClusterConfig (..),
    createClusterClient,
    closeClusterClient,
    executeClusterCommand,
    withRetry,
    parseRedirectionError,
    handleMoved,
    handleAsk,
  )
where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (NotConnectedTLSClient))
import Cluster (ClusterTopology (..), ClusterNode (..), NodeAddress (..), calculateSlot, findNodeForSlot, parseClusterSlots)
import ConnectionPool (ConnectionPool, PoolConfig (..), closePool, createPool, getOrCreateConnection)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException, catch, throwIO, try)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.Vector as V
import Data.Word (Word16)
import RedisCommandClient (ClientState (..), RedisCommandClient (..), RedisCommands (..), parseWith, runRedisCommandClient)
import Resp (Encodable (..), RespData (..))
import qualified Data.ByteString.Builder as Builder
import Control.Monad.State qualified as State

-- | Error types specific to cluster operations
data ClusterError
  = MovedError Word16 NodeAddress -- Slot and new address
  | AskError Word16 NodeAddress -- Slot and temporary address
  | ClusterDownError String
  | TryAgainError String
  | CrossSlotError String
  | MaxRetriesExceeded String
  | TopologyError String
  | ConnectionError String
  deriving (Show, Eq)

-- | Redirection information parsed from errors
data RedirectionInfo = RedirectionInfo
  { redirSlot :: Word16,
    redirHost :: String,
    redirPort :: Int
  }
  deriving (Show, Eq)

-- | Configuration for cluster client
data ClusterConfig = ClusterConfig
  { clusterSeedNode :: NodeAddress, -- Initial node to connect to
    clusterPoolConfig :: PoolConfig,
    clusterMaxRetries :: Int, -- Maximum retry attempts (default: 3)
    clusterRetryDelay :: Int, -- Initial retry delay in microseconds (default: 100000 = 100ms)
    clusterTopologyRefreshInterval :: Int -- Seconds between topology refreshes (default: 60)
  }
  deriving (Show)

-- | Cluster client that manages connections to multiple nodes
data ClusterClient client = ClusterClient
  { clusterTopology :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig :: ClusterConfig
  }

-- | Create a new cluster client by connecting to seed node and discovering topology
createClusterClient ::
  (Client client) =>
  ClusterConfig ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (ClusterClient client)
createClusterClient config connector = do
  pool <- createPool (clusterPoolConfig config)
  topology <- newTVarIO undefined -- Will be initialized below
  let client = ClusterClient topology pool config

  -- Discover initial topology
  refreshTopology client connector

  return client

-- | Close all connections in the cluster client
closeClusterClient :: (Client client) => ClusterClient client -> IO ()
closeClusterClient client = closePool (clusterConnectionPool client)

-- | Refresh cluster topology by querying CLUSTER SLOTS
refreshTopology ::
  (Client client) =>
  ClusterClient client ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO ()
refreshTopology client connector = do
  let seedNode = clusterSeedNode (clusterConfig client)
  conn <- getOrCreateConnection (clusterConnectionPool client) seedNode connector
  
  -- Use clusterSlots command from RedisCommands
  let clientState = ClientState conn BS.empty
  response <- State.evalStateT (runRedisCommandClient clusterSlots) clientState
  
  currentTime <- getCurrentTime
  case parseClusterSlots response currentTime of
    Left err -> throwIO $ userError $ "Failed to parse cluster topology: " ++ err
    Right topology -> atomically $ writeTVar (clusterTopology client) topology

-- | Execute a Redis command with cluster awareness and automatic redirection handling
executeClusterCommand ::
  (Client client) =>
  ClusterClient client ->
  ByteString -> -- The key to determine routing
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
executeClusterCommand client key action connector = do
  slot <- calculateSlot key
  withRetry (clusterMaxRetries (clusterConfig client)) (clusterRetryDelay (clusterConfig client)) $ do
    executeOnSlot client slot action connector

-- | Execute a command on the node responsible for a given slot
executeOnSlot ::
  (Client client) =>
  ClusterClient client ->
  Word16 ->
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
executeOnSlot client slot action connector = do
  topology <- atomically $ readTVar (clusterTopology client)
  case findNodeForSlot topology slot of
    Nothing -> return $ Left $ TopologyError $ "No node found for slot " ++ show slot
    Just nodeId -> do
      -- Look up the node address from the topology
      case Map.lookup nodeId (topologyNodes topology) of
        Nothing -> return $ Left $ TopologyError $ "Node ID " ++ T.unpack nodeId ++ " not found in topology"
        Just node -> executeOnNode client (nodeAddress node) action connector

-- | Execute a command on a specific node
executeOnNode ::
  (Client client) =>
  ClusterClient client ->
  NodeAddress ->
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
executeOnNode client nodeAddr action connector = do
  result <- try $ do
    conn <- getOrCreateConnection (clusterConnectionPool client) nodeAddr connector
    let clientState = ClientState conn BS.empty
    State.evalStateT (runRedisCommandClient action) clientState
  
  case result of
    Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
    Right value -> return $ Right value

-- | Retry logic with exponential backoff
withRetry ::
  Int -> -- Max retries
  Int -> -- Initial delay (microseconds)
  IO (Either ClusterError a) ->
  IO (Either ClusterError a)
withRetry maxRetries initialDelay action = go 0 initialDelay
  where
    go attempt delay
      | attempt >= maxRetries = return $ Left $ MaxRetriesExceeded $ "Max retries (" ++ show maxRetries ++ ") exceeded"
      | otherwise = do
          result <- action
          case result of
            Left (TryAgainError msg) -> do
              -- Exponential backoff
              threadDelay delay
              go (attempt + 1) (delay * 2)
            Left err@(MovedError _ _) -> return $ Left err -- These should be handled at a higher level
            Left err@(AskError _ _) -> return $ Left err
            Left err -> return $ Left err
            Right value -> return $ Right value

-- | Parse redirection error messages
-- Format: "MOVED 3999 127.0.0.1:6381" or "ASK 3999 127.0.0.1:6381"
parseRedirectionError :: String -> String -> Maybe RedirectionInfo
parseRedirectionError errorType msg =
  case words msg of
    (prefix : slotStr : hostPort : _)
      | prefix == errorType ->
          case reads slotStr of
            [(slot, "")] ->
              case break (== ':') hostPort of
                (host, ':' : portStr) ->
                  case reads portStr of
                    [(port, "")] -> Just $ RedirectionInfo (fromIntegral slot) host port
                    _ -> Nothing
                _ -> Nothing
            _ -> Nothing
    _ -> Nothing

-- | Handle MOVED error by updating topology and retrying
handleMoved ::
  (Client client) =>
  ClusterClient client ->
  RedirectionInfo ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO ()
handleMoved client redir connector = do
  -- Update topology slot mapping
  let newAddr = NodeAddress (redirHost redir) (redirPort redir)
  atomically $ do
    topology <- readTVar (clusterTopology client)
    let slots = topologySlots topology
        updatedSlots = slots V.// [(fromIntegral (redirSlot redir), T.pack $ show newAddr)]
        updatedTopology = topology {topologySlots = updatedSlots}
    writeTVar (clusterTopology client) updatedTopology

-- | Handle ASK error by sending ASKING command and retrying
handleAsk ::
  (Client client) =>
  ClusterClient client ->
  RedirectionInfo ->
  RedisCommandClient client a ->
  (NodeAddress -> IO (client 'Connected)) ->
  IO (Either ClusterError a)
handleAsk client redir action connector = do
  let askAddr = NodeAddress (redirHost redir) (redirPort redir)
  
  -- Execute ASKING followed by the original command
  result <- try $ do
    conn <- getOrCreateConnection (clusterConnectionPool client) askAddr connector
    let clientState = ClientState conn BS.empty
    State.evalStateT (runRedisCommandClient $ do
      -- Send ASKING command
      cs <- State.get
      let conn' = getClient cs
      liftIO $ send conn' (Builder.toLazyByteString $ encode (RespArray [RespBulkString "ASKING"]))
      _ <- parseWith (receive conn')
      -- Execute original command
      action
      ) clientState
  
  case result of
    Left (e :: SomeException) -> return $ Left $ ConnectionError $ show e
    Right value -> return $ Right value
