{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Exception (try)
import           Control.Monad     (filterM)
import           Database.Redis
import           System.Directory  (doesFileExist)
import           Test.Hspec

main :: IO ()
main = hspec $ describe "Database.Redis timeout-aware public API" $ do
  it "exports the migration-compatible ordinary cluster error" $ do
    RedisCommandError "ERR full server cause"
      `shouldBe` RedisCommandError "ERR full server cause"

  it "keeps raw cluster frame execution out of public facades" $ do
    clientSource <- findSource
      [ "lib/cluster/Database/Redis/Cluster/Client.hs"
      , "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Client.hs"
      ]
    rootSource <- findSource
      [ "lib/redis/Database/Redis.hs"
      , "hask-redis-mux/lib/redis/Database/Redis.hs"
      ]
    cabalSource <- findSource
      [ "hask-redis-mux.cabal"
      , "hask-redis-mux/hask-redis-mux.cabal"
      ]
    publicExports <- takeWhile (/= ") where") . lines <$> readFile clientSource
    unlines publicExports `shouldNotContain` "executeRawClusterCommand"
    unlines publicExports `shouldNotContain` "RawClusterRoute"
    rootFacade <- readFile rootSource
    rootFacade `shouldNotContain`
      "Database.Redis.Cluster.Internal.RawCommand"
    rootFacade `shouldNotContain` "executeRawClusterCommand"
    rootFacade `shouldNotContain` "RawClusterRoute"
    topLevelReexports <- takeWhile (/= "library resp") . lines <$> readFile cabalSource
    unlines topLevelReexports `shouldNotContain`
      "Database.Redis.Cluster.Internal.RawCommand"

  it "exports redaction-safe cluster authentication policies" $ do
    let createAuthenticated
          :: ClusterConfig
          -> ClusterAuthentication
          -> Connector PlainTextClient
          -> IO (ClusterClient PlainTextClient)
        createAuthenticated = createClusterClientWithAuthentication
        withAuthenticated
          :: ClusterConfig
          -> ClusterAuthentication
          -> Connector PlainTextClient
          -> (ClusterClient PlainTextClient -> IO ())
          -> IO ()
        withAuthenticated = withClusterClientAuthentication
    show (ClusterPassword "public-password")
      `shouldBe` "ClusterPassword <redacted>"
    show (ClusterACL "public-user" "public-password")
      `shouldBe` "ClusterACL <redacted> <redacted>"
    createAuthenticated `seq` withAuthenticated `seq` return ()

  it "exports and enforces the documented direct TLS deadline" $ do
    result <- try $ connectTLSWithTimeout 0 "redis.example.net" 6380
      :: IO (Either ConnectionSetupException (TLSClient 'Connected))
    assertImmediateTimeout (NodeAddress "redis.example.net" 6380) result

  it "exports and enforces the documented standalone connector deadline" $ do
    let endpoint = NodeAddress "redis.example.net" 6379
    result <- try $ clusterPlaintextConnectorWithTimeout 0 endpoint
      :: IO (Either ConnectionSetupException (PlainTextClient 'Connected))
    assertImmediateTimeout endpoint result

assertImmediateTimeout
  :: NodeAddress
  -> Either ConnectionSetupException client
  -> Expectation
assertImmediateTimeout endpoint = \case
  Left timeoutError -> do
    connectionTimeoutPhase timeoutError `shouldBe` DNSResolution
    connectionTimeoutEndpoint timeoutError `shouldBe` endpoint
    connectionTimeoutSeconds timeoutError `shouldBe` 0
  Right _ ->
    expectationFailure "timeout-aware helper unexpectedly connected"

findSource :: [FilePath] -> IO FilePath
findSource candidates = do
  matches <- filterM doesFileExist candidates
  case matches of
    path : _ -> return path
    [] -> expectationFailure "Could not locate public API source" >> fail "unreachable"
