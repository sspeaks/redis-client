{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Test.Hspec

import qualified ClusterE2E.Basic           as Basic
import qualified ClusterE2E.Fill            as Fill
import qualified ClusterE2E.Cli             as Cli
import qualified ClusterE2E.Tunnel          as Tunnel
import qualified ClusterE2E.TopologyRefresh as TopologyRefresh

main :: IO ()
main = hspec $ do
  describe "Cluster E2E Tests" $ do
    Basic.spec
    Fill.spec
    Cli.spec
    Tunnel.spec
    TopologyRefresh.spec
