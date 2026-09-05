{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands.Spec
  ( GeneratedCommandSpec(..)
  , GeneratedArgument(..)
  ) where

import           Data.ByteString (ByteString)

data GeneratedCommandSpec = GeneratedCommandSpec
  { gcsTokens    :: [ByteString]
  , gcsArity     :: Int
  , gcsFlags     :: [ByteString]
  , gcsArguments :: [GeneratedArgument]
  }
  deriving (Eq, Show)

data GeneratedArgument = GeneratedArgument
  { gaType         :: ByteString
  , gaName         :: ByteString
  , gaToken        :: Maybe ByteString
  , gaOptional     :: Bool
  , gaMultiple     :: Bool
  , gaKeySpecIndex :: Maybe Int
  , gaChildren     :: [GeneratedArgument]
  , gaAlternatives :: [[GeneratedArgument]]
  }
  deriving (Eq, Show)
