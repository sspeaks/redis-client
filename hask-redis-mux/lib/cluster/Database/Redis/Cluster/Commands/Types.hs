{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands.Types
  ( BeginSearch (..)
  , FindKeys (..)
  , GeneratedKeySpec (..)
  , GeneratedCommandSpec (..)
  ) where

import           Data.ByteString (ByteString)

data BeginSearch
  = BeginIndex !Int
  | BeginKeyword !ByteString !Int
  | BeginSearchUnsupported
  deriving (Eq, Show)

data FindKeys
  = FindRange !Int !Int !Int
  | FindKeyNum !Int !Int !Int
  | FindKeysUnsupported
  deriving (Eq, Show)

data GeneratedKeySpec = GeneratedKeySpec
  { generatedBeginSearch :: !BeginSearch
  , generatedFindKeys    :: !FindKeys
  } deriving (Eq, Show)

data GeneratedCommandSpec = GeneratedCommandSpec
  { generatedCommandName     :: !ByteString
  , generatedCommandArity    :: !Int
  , generatedCommandKeySpecs :: ![GeneratedKeySpec]
  } deriving (Eq, Show)
