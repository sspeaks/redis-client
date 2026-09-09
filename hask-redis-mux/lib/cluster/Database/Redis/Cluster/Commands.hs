{-# LANGUAGE OverloadedStrings #-}

-- | Shared command classification for cluster routing
-- This module provides a compatibility facade over generated Redis command metadata.
--
-- @since 0.1.0.0
module Database.Redis.Cluster.Commands
  ( keylessCommands,
    requiresKeyCommands,
    CommandRouting (..),
    classifyCommand,
  )
where

import           Data.ByteString                                 (ByteString)
import           Database.Redis.Cluster.Internal.CommandGrammar
import           Database.Redis.Cluster.Internal.CommandMetadata

-- | Result of classifying a command for cluster routing
data CommandRouting
  = KeylessRoute        -- ^ Route to any master node
  | KeyedRoute ByteString  -- ^ Route by this key's hash slot
  | CommandError String    -- ^ Invalid command (e.g., missing required key)

-- | Classify a Redis command for cluster routing.
-- Returns 'KeylessRoute' for commands like PING or AUTH that can go to any master,
-- 'KeyedRoute' with the routing key for commands that target a specific slot,
-- or 'CommandError' if a key-requiring command is missing its key argument.
classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  case classifyCommandFrame (cmd : args) of
    Right FrameKeyless -> KeylessRoute
    Right (FrameSingleSlot key _) -> KeyedRoute key
    Right (FrameCrossSlot _) ->
      CommandError "CROSSSLOT Keys in request don't hash to the same slot"
    Left errorValue -> CommandError (renderCommandGrammarError errorValue)

-- | Commands that don't require a key argument (route to any master node)
-- These commands can be executed on any master node in the cluster
-- This compatibility list is derived from the immutable Redis 7.2 metadata snapshot.
keylessCommands :: [ByteString]
keylessCommands = commandIdentity <$> filter (null . commandKeySpecs) commandMetadata

-- | Commands that require a key argument (route by key's hash slot)
-- These commands must be routed to the node responsible for the key's hash slot
-- This compatibility list is derived from the immutable Redis 7.2 metadata snapshot.
requiresKeyCommands :: [ByteString]
requiresKeyCommands = commandIdentity <$> filter (not . null . commandKeySpecs) commandMetadata
