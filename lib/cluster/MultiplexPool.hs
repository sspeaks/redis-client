{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Pool of 'Multiplexer's for cluster-mode usage.
--
-- Manages a fixed number of multiplexed connections per node, distributing
-- commands via round-robin. Automatically reconnects dead multiplexers.
--
-- @
-- pool <- createMultiplexPool connector 2  -- 2 multiplexers per node
-- resp <- submitToNode pool nodeAddr cmdBytes
-- closeMultiplexPool pool
-- @
module MultiplexPool
  ( MultiplexPool
  , MultiplexPoolConfig (..)
  , createMultiplexPool
  , submitToNode
  , closeMultiplexPool
  ) where

import Client (Client (..))
import Cluster (NodeAddress (..))
import Connector (Connector)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar)
import Control.Exception (SomeException, catch, throwIO, try)
import Data.IORef (IORef, newIORef, atomicModifyIORef')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Vector (Vector)
import qualified Data.Vector as V
import Multiplexer
  ( Multiplexer
  , createMultiplexer
  , destroyMultiplexer
  , isMultiplexerAlive
  , submitCommand
  )
import Resp (RespData)
import qualified Data.ByteString.Builder as Builder

-- | Configuration for a multiplexer pool.
data MultiplexPoolConfig = MultiplexPoolConfig
  { muxPerNode :: !Int  -- ^ Number of multiplexed connections per node (default: 2)
  }
  deriving (Show)

-- | Per-node state: a vector of multiplexers and a round-robin counter.
data NodeMuxState = NodeMuxState
  { nodeMuxes   :: !(Vector Multiplexer)
  , nodeMuxNext :: !(IORef Int)  -- round-robin index
  }

-- | A pool of multiplexers, keyed by node address.
-- Uses MVar for safe concurrent access to the node map.
data MultiplexPool client = MultiplexPool
  { poolNodes     :: !(MVar (Map NodeAddress NodeMuxState))
  , poolConnector :: !(Connector client)
  , poolConfig    :: !MultiplexPoolConfig
  }

-- | Create a new empty multiplexer pool.
-- Multiplexers are created lazily when a node is first accessed.
createMultiplexPool
  :: (Client client)
  => Connector client
  -> MultiplexPoolConfig
  -> IO (MultiplexPool client)
createMultiplexPool connector config = do
  nodes <- newMVar Map.empty
  return $ MultiplexPool nodes connector config

-- | Submit a pre-encoded RESP command (as a Builder) to the multiplexer for a given node.
-- Creates multiplexers on demand if the node hasn't been seen before.
-- Automatically replaces dead multiplexers.
submitToNode
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> Builder.Builder
  -> IO RespData
submitToNode pool addr cmdBuilder = do
  mux <- pickMultiplexer pool addr
  submitCommand mux cmdBuilder

-- | Pick a multiplexer for the given node using round-robin.
-- Creates the node's multiplexers on first access.
-- Replaces dead multiplexers transparently.
pickMultiplexer
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO Multiplexer
pickMultiplexer pool addr = do
  nodeState <- getOrCreateNodeState pool addr
  pickFromNode pool addr nodeState

-- | Get or create the multiplexer state for a node.
-- Uses readMVar for the common path (node exists) to avoid serialization.
-- Falls back to modifyMVar only on cache miss (first access to a node).
getOrCreateNodeState
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO NodeMuxState
getOrCreateNodeState pool addr = do
  m <- readMVar (poolNodes pool)
  case Map.lookup addr m of
    Just state -> return state
    Nothing -> modifyMVar (poolNodes pool) $ \m' ->
      case Map.lookup addr m' of
        Just state -> return (m', state)
        Nothing -> do
          state <- initNodeState pool addr
          return (Map.insert addr state m', state)

-- | Initialize multiplexers for a node.
initNodeState
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> IO NodeMuxState
initNodeState pool addr = do
  let n = muxPerNode (poolConfig pool)
  muxes <- V.generateM n (\_ -> createOneMux (poolConnector pool) addr)
  counter <- newIORef 0
  return $ NodeMuxState muxes counter

-- | Create a single multiplexer for a node address.
createOneMux
  :: (Client client)
  => Connector client
  -> NodeAddress
  -> IO Multiplexer
createOneMux connector addr = do
  conn <- connector addr
  createMultiplexer conn (receive conn)

-- | Pick the next multiplexer from a node's pool, replacing dead ones.
pickFromNode
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> NodeMuxState
  -> IO Multiplexer
pickFromNode pool addr state = do
  let muxes = nodeMuxes state
      n = V.length muxes
  idx <- atomicModifyIORef' (nodeMuxNext state) $ \i ->
    let next = (i + 1) `mod` n in (next, i)
  let mux = muxes V.! (idx `mod` n)
  alive <- isMultiplexerAlive mux
  if alive
    then return mux
    else replaceMux pool addr state (idx `mod` n)

-- | Replace a dead multiplexer at a given index.
replaceMux
  :: (Client client)
  => MultiplexPool client
  -> NodeAddress
  -> NodeMuxState
  -> Int
  -> IO Multiplexer
replaceMux pool addr state idx = do
  -- Try to destroy the old one (ignore errors)
  let oldMux = nodeMuxes state V.! idx
  destroyMultiplexer oldMux `catch` \(_ :: SomeException) -> return ()

  -- Create replacement
  result <- try $ createOneMux (poolConnector pool) addr
  case result of
    Right newMux -> do
      -- Update the vector in the shared map
      let newMuxes = nodeMuxes state V.// [(idx, newMux)]
      modifyMVar (poolNodes pool) $ \m -> do
        let newState = state { nodeMuxes = newMuxes }
        return (Map.insert addr newState m, newMux)
    Left (e :: SomeException) -> throwIO e

-- | Tear down all multiplexers across all nodes.
closeMultiplexPool
  :: MultiplexPool client
  -> IO ()
closeMultiplexPool pool = do
  modifyMVar (poolNodes pool) $ \m -> do
    mapM_ closeNodeState (Map.elems m)
    return (Map.empty, ())
  where
    closeNodeState state =
      V.mapM_ (\mux -> destroyMultiplexer mux `catch` \(_ :: SomeException) -> return ())
            (nodeMuxes state)
