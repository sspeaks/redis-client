{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module ClusterCli (
  routeAndExecuteCommand
)
where

import           Client                     (Client (receive, send))
import           ClusterCommandClient       (ClusterClientState (..),
                                             ClusterError (..))
import qualified ClusterCommandClient
import           ClusterCommands            (CommandRouting (..),
                                             classifyCommand)
import           Control.Monad.IO.Class     (liftIO)
import qualified Control.Monad.State.Strict as State
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BSC
import           RedisCommandClient         (ClientState (ClientState),
                                             RedisCommandClient, parseWith)
import           Resp                       (Encodable (encode),
                                             RespData (RespArray, RespBulkString))

-- | Route and execute command parts via ClusterCommandClient
routeAndExecuteCommand :: (Client client) => [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
routeAndExecuteCommand [] = return $ Left "Empty command"
routeAndExecuteCommand (cmd:args) = do
  case classifyCommand cmd args of
    KeylessRoute   -> executeKeylessCommand (cmd:args)
    KeyedRoute key -> executeKeyedCommand key (cmd:args)
    CommandError e -> return $ Left e

-- | Execute a keyless command (routing to any master node)
executeKeylessCommand :: (Client client) => [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
executeKeylessCommand parts = do
  ClusterClientState clusterClient connector <- State.get
  result <- liftIO $ ClusterCommandClient.executeKeylessClusterCommand clusterClient (sendRespCommand parts) connector
  return $ case result of
    Left err   -> Left (show err)
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
