{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Exception (displayException, toException, try)
import           Control.Monad     (filterM)
import           Database.Redis
import           System.Directory  (doesFileExist)
import           Test.Hspec

main :: IO ()
main = hspec $ describe "Database.Redis timeout-aware public API" $ do
  it "exports the migration-compatible ordinary cluster error" $ do
    RedisCommandError "ERR full server cause"
      `shouldBe` RedisCommandError "ERR full server cause"

  it "exports the explicit unsafe CLIENT REPLY mode error" $ do
    ClientReplyModeUnsupported SKIP
      `shouldBe` ClientReplyModeUnsupported SKIP

  it "exports the uncertain-write error constructor and accessors" $ do
    let failure = ClientReplyUncertainWrite
          { clientReplyPrimaryError = toException $ userError "transfer failed"
          , clientReplyCloseError = toException $ userError "close failed"
          }
    displayException (clientReplyPrimaryError failure)
      `shouldContain` "transfer failed"
    displayException (clientReplyCloseError failure)
      `shouldContain` "close failed"
    show failure `shouldContain` "CLIENT REPLY SKIP transfer failed"

  it "documents synchronous reply-mode rejection and safe sequential transitions" $ do
    commandSource <- findSource
      [ "lib/redis-command-client/Database/Redis/Command.hs"
      , "hask-redis-mux/lib/redis-command-client/Database/Redis/Command.hs"
      ]
    source <- readFile commandSource
    source `shouldContain` "@SKIP@ is not composable through 'clientReply'"
    source `shouldContain` "atomically bind it to the command"
    source `shouldContain` "synchronously reject @OFF@ and"
    source `shouldContain` "/before/ connection acquisition,"
    source `shouldContain` "queueing, bytes sent, slot allocation, or reply-stream/state mutation"
    source `shouldContain` "without reading a reply, so it returns 'Nothing'"
    source `shouldContain` "every intervening command /must/ use"
    source `shouldContain` "ordinary reply-waiting commands are invalid and may block or"
    source `shouldContain` "consumes its own @OK@ reply, and restores normal replies"
    source `shouldContain` "closes the physical"
    source `shouldContain` "If close succeeds, the original"
    source `shouldContain` "transfer error is rethrown unchanged"
    source `shouldContain` "If transfer and close both fail"
    source `shouldContain` "synchronously, 'ClientReplyUncertainWrite' retains both failures"
    source `shouldContain` "asynchronous transfer failure takes precedence"
    source `shouldContain` "asynchronous close failure takes precedence"
    source `shouldContain` "When exactly one failure is asynchronous"
    source `shouldContain` "synchronous counterpart is reported to standard error"
    source `shouldContain` "If both failures are"
    source `shouldContain` "asynchronous, the transfer failure wins and the close failure is reported"
    source `shouldContain` "This exception never wraps an asynchronous exception"
    source `shouldContain` "connection passed to this function must not be reused"

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
    commandsSource <- findSource
      [ "lib/cluster/Database/Redis/Cluster/Commands.hs"
      , "hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands.hs"
      ]
    publicExports <- takeWhile (/= ") where") . lines <$> readFile clientSource
    unlines publicExports `shouldNotContain` "executeRawClusterCommand"
    unlines publicExports `shouldNotContain` "RawClusterRoute"
    rootFacade <- readFile rootSource
    rootFacade `shouldNotContain`
      "Database.Redis.Cluster.Internal.RawCommand"
    rootFacade `shouldNotContain`
      "Database.Redis.Cluster.Internal.CommandGrammar"
    rootFacade `shouldNotContain`
      "Database.Redis.Cluster.Internal.CommandMetadata"
    rootFacade `shouldNotContain` "executeRawClusterCommand"
    rootFacade `shouldNotContain` "RawClusterRoute"
    rootFacade `shouldNotContain` "sendClientReplySkipAndCommand"
    topLevelReexports <- takeWhile (/= "library resp") . lines <$> readFile cabalSource
    unlines topLevelReexports `shouldNotContain`
      "Database.Redis.Cluster.Internal.RawCommand"
    commandsFacade <- readFile commandsSource
    commandsFacade `shouldNotContain` "deriving (Eq, Show)"

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
