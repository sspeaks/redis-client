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
import           Data.Char                  (toUpper)
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
-- Uses explicit command lists to determine routing strategy
routeAndExecuteCommand :: (Client client) => [BS.ByteString] -> ClusterCommandClient.ClusterCommandClient client (Either String RespData)
routeAndExecuteCommand [] = return $ Left "Empty command"
routeAndExecuteCommand (cmd:args) = do
  let cmdUpper = BS.map toUpper cmd  -- Commands are ASCII, so toUpper is safe
      cmdStr = BS.unpack cmd
  
  -- Route based on command type using explicit lists
  -- Keyless commands (no key argument) - route to any master
  if cmdUpper `elem` keylessCommands
    then executeKeylessCommand (cmd:args)
    -- Keyed commands (first argument is the key) - route by key slot
    else case args of
      [] -> if cmdUpper `elem` requiresKeyCommands
              then return $ Left $ "Command " ++ cmdStr ++ " requires a key argument"
              else executeKeylessCommand (cmd:args)  -- Unknown command without args, try keyless
      (key:_) -> executeKeyedCommand key (cmd:args)

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

-- | Commands that don't require a key (route to any master)
-- Note: This list is based on Redis 7.x commands and may need updates for newer versions
-- See CLUSTERING_IMPLEMENTATION_PLAN.md for future work on eliminating this list
keylessCommands :: [BS.ByteString]
keylessCommands = 
  [ "PING", "AUTH", "FLUSHALL", "FLUSHDB", "DBSIZE"
  , "CLUSTER", "INFO", "TIME", "CLIENT", "CONFIG"
  , "BGREWRITEAOF", "BGSAVE", "SAVE", "LASTSAVE"
  , "SHUTDOWN", "SLAVEOF", "REPLICAOF", "ROLE"
  , "ECHO", "SELECT", "QUIT", "COMMAND"
  ]

-- | Commands that require a key argument
-- Note: This list is based on Redis 7.x commands and may need updates for newer versions
-- See CLUSTERING_IMPLEMENTATION_PLAN.md for future work on eliminating this list
requiresKeyCommands :: [BS.ByteString]
requiresKeyCommands =
  [ "GET", "SET", "DEL", "EXISTS", "INCR", "DECR"
  , "HGET", "HSET", "HDEL", "HKEYS", "HVALS", "HGETALL", "HEXISTS"
  , "LPUSH", "RPUSH", "LPOP", "RPOP", "LRANGE", "LLEN", "LINDEX"
  , "SADD", "SREM", "SMEMBERS", "SCARD", "SISMEMBER"
  , "ZADD", "ZREM", "ZRANGE", "ZCARD"
  , "EXPIRE", "TTL", "PERSIST"
  , "MGET", "MSET", "SETNX", "PSETEX"
  , "APPEND", "GETRANGE", "SETRANGE", "STRLEN"
  , "GETEX", "GETDEL", "SETEX"
  ]
