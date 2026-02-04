{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterCli
  ( executeCommandInCluster
  ) where

import           Client                     (Client (receive, send))
import           ClusterCommandClient       (ClusterClientState (..),
                                             ClusterError (..))
import qualified ClusterCommandClient
import           Control.Monad.IO.Class     (liftIO)
import qualified Control.Monad.State.Strict as State
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BSC
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommandClient, parseWith)
import           Resp                       (Encodable (encode),
                                             RespData (RespArray, RespBulkString))

-- | Execute a command in cluster mode with proper routing and error handling
-- This is the main entry point for executing user commands in cluster CLI mode
executeCommandInCluster :: (Client client) => String -> ClusterCommandClient.ClusterCommandClient client ()
executeCommandInCluster cmd = do
  let parts = words cmd
  case parts of
    [] -> return ()
    (command:args) -> do
      result <- routeAndExecuteCommand (map BS.pack (command:args))
      case result of
        Left err -> liftIO $ putStrLn $ "Error: " ++ err
        Right response -> liftIO $ print response

-- | Route and execute command parts via ClusterCommandClient
-- Uses heuristic-based routing to avoid maintaining hardcoded command lists
routeAndExecuteCommand :: (Client client) => [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
routeAndExecuteCommand [] = return $ Left "Empty command"
routeAndExecuteCommand (cmd:args) = do
  -- Heuristic-based routing strategy:
  -- 1. If command has no arguments, route to any master (PING, INFO, DBSIZE, etc.)
  -- 2. If first argument exists, assume it's a key and route by slot
  -- 3. Let Redis handle invalid commands - it will return appropriate errors
  case args of
    [] -> executeKeylessCommand (cmd:args)
    (firstArg:_) -> 
      -- Check if first argument looks like a flag/option (starts with -)
      if BS.isPrefixOf "-" firstArg || BS.isPrefixOf "--" firstArg
        then executeKeylessCommand (cmd:args)  -- Route to any master
        else executeKeyedCommand firstArg (cmd:args)  -- Route by key slot

-- | Execute a keyless command (routing to any master node)
executeKeylessCommand :: (Client client) => [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
executeKeylessCommand parts = do
  ClusterClientState clusterClient connector <- State.get
  result <- liftIO $ ClusterCommandClient.executeKeylessClusterCommand clusterClient (sendRespCommand parts) connector
  return $ case result of
    Left err -> Left (show err)
    Right resp -> Right resp

-- | Execute a keyed command (routing by key's slot)
executeKeyedCommand :: (Client client) => BS.ByteString -> [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
executeKeyedCommand key parts = do
  ClusterClientState clusterClient connector <- State.get
  result <- liftIO $ ClusterCommandClient.executeClusterCommand clusterClient key (sendRespCommand parts) connector
  return $ case result of
    Left (CrossSlotError msg) -> Left $ "CROSSSLOT error: " ++ msg ++ "\nHint: Use hash tags like {user}:key to ensure keys map to the same slot"
    Left err -> Left (show err)
    Right resp -> Right resp

-- | Send RESP command and receive response
-- This function operates within RedisCommandClient monad to send raw commands
sendRespCommand :: (Client client) => [BS.ByteString] -> RedisCommandClient client RespData
sendRespCommand parts = do
  ClientState client _ <- State.get
  let respArray = RespArray $ map (RespBulkString . BSC.fromStrict) parts
      encoded = Builder.toLazyByteString $ encode respArray
  send client encoded
  parseWith (receive client)
