{-# LANGUAGE OverloadedStrings #-}

module Main where

import Test.Hspec

import qualified LibraryE2E.ApiTests            as Api
import qualified LibraryE2E.ConnectionPoolTests  as ConnectionPool
import qualified LibraryE2E.ConcurrencyTests     as Concurrency
import qualified LibraryE2E.ResilienceTests       as Resilience
import qualified LibraryE2E.TopologyTests        as Topology
import qualified LibraryE2E.StandaloneTests      as Standalone
import qualified LibraryE2E.StandaloneConcurrencyTests as StandaloneConcurrency

main :: IO ()
main = hspec $ do
  describe "Library E2E Tests" $ do
    Api.spec
    ConnectionPool.spec
    Topology.spec
    Concurrency.spec
    Resilience.spec
    Standalone.spec
    StandaloneConcurrency.spec
