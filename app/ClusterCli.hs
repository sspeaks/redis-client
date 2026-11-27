{-# LANGUAGE OverloadedStrings #-}

module ClusterCli (
  routeAndExecuteCommand
)
where

import           Control.Monad.IO.Class        (liftIO)
import qualified Control.Monad.State.Strict    as State
import qualified Data.ByteString.Char8         as BS8
import           Database.Redis.Client         (Client)
import qualified Database.Redis.Cluster.Client as ClusterCommandClient
import           Database.Redis.Resp           (RespData (RespArray, RespBulkString, RespError))

-- | Forward command parts through the cluster client. Error replies, whether
-- from Redis or rejected locally, are returned as 'Left' with their RESP text.
routeAndExecuteCommand :: (Client client) => [BS8.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
routeAndExecuteCommand [] = return $ Left "Empty command"
routeAndExecuteCommand parts = do
  clusterClient <- State.get
  reply <- liftIO $
    ClusterCommandClient.forwardClusterFrame clusterClient (RespArray $ map RespBulkString parts)
  return $ case reply of
    RespError message
      | "CROSSSLOT " `BS8.isPrefixOf` message -> Left $
          BS8.unpack message
            ++ "\nHint: Use hash tags like {user}:key to ensure keys map to the same slot"
      | otherwise -> Left (BS8.unpack message)
    response -> Right response
