{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString                 as BS
import           Database.Redis.Cluster          (calculateSlot)
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommand,
                                                  keylessCommands,
                                                  requiresKeyCommands)
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec =
    describe "metadata-driven command grammar" $ do
        it "extracts fixed binary keys without changing bytes and matches command case" $ do
            let binaryKey = BS.pack [0, 123, 255, 125]
            shouldRouteBy "gEt" [binaryKey] binaryKey

        it "rejects missing and excess exact-arity arguments" $ do
            shouldReject "GET" [] "GET has invalid arity: expected 2 argument(s), got 1"
            shouldReject
                "GET"
                ["key", "extra"]
                "GET has invalid arity: expected 2 argument(s), got 3"

        it "extracts range keys and applies existing hash-tag semantics" $ do
            shouldRouteBy "MGET" ["{slot}:one", "{slot}:two"] "{slot}:one"
            shouldReject
                "MGET"
                ["one", "two"]
                "CROSSSLOT Keys in request don't hash to the same slot"
            calculateSlot "{tag}:one" `shouldBe` calculateSlot "{tag}:two"

        it "handles negative last-key and stepped range specifications" $ do
            shouldRouteBy "BLPOP" ["{same}:one", "{same}:two", "1"] "{same}:one"
            shouldRouteBy
                "MSET"
                ["{same}:one", "one", "{same}:two", "two"]
                "{same}:one"
            shouldReject "MSET" ["key", "value", "dangling"] "MSET has malformed arguments"

        it "extracts key-count keys and validates malformed and insufficient counts" $ do
            shouldRouteBy
                "EVAL"
                ["return 1", "2", "{same}:one", "{same}:two"]
                "{same}:one"
            shouldReject "EVAL" ["return 1", "two"] "EVAL has an invalid key count"
            shouldReject
                "EVAL"
                ["return 1", "2", "only-one"]
                "EVAL has malformed key arguments"
            shouldReject "EVAL" ["return 1", "-1"] "EVAL has an invalid key count"
            shouldReject
                "EVAL"
                ["return 1", "9223372036854775808", "key"]
                "EVAL has an invalid key count"
            shouldReject
                "EVAL"
                ["return 1", "9223372036854775807", "key"]
                "EVAL has malformed key arguments"

        it "allows zero key-count only for NO_MANDATORY_KEYS commands" $ do
            shouldRouteKeyless "EVALSHA" ["hash", "0"]
            shouldRouteKeyless "FCALL" ["function", "0", "argument"]
            shouldReject "LMPOP" ["0", "key", "LEFT"] "LMPOP has an invalid key count"
            shouldReject "BLMPOP" ["0", "0", "key", "LEFT"] "BLMPOP has an invalid key count"
            shouldReject "ZMPOP" ["0", "key", "LEFT"] "ZMPOP has an invalid key count"
            shouldReject
                "ZINTERCARD"
                ["0", "key"]
                "ZINTERCARD has an invalid key count"

        it "validates LMPOP, BLMPOP, and ZMPOP key counts and direction tokens" $ do
            shouldRouteBy "LMPOP" ["1", "{same}:one", "LEFT"] "{same}:one"
            shouldRouteBy "BLMPOP" ["0", "1", "{same}:one", "RIGHT"] "{same}:one"
            shouldRouteBy "ZMPOP" ["1", "{same}:one", "MIN"] "{same}:one"
            shouldReject
                "BLMPOP"
                ["0", "1", "{same}:one", "{other}:hidden", "LEFT"]
                "BLMPOP has malformed key arguments"
            shouldReject
                "LMPOP"
                ["1", "key", "SIDEWAYS"]
                "LMPOP has malformed arguments"

        it "extracts every key spec and validates ZUNIONSTORE trailing grammar" $ do
            shouldRouteBy
                "ZUNIONSTORE"
                ["{same}:destination", "2", "{same}:one", "{same}:two"]
                "{same}:destination"
            shouldRouteBy
                "ZUNIONSTORE"
                [ "{same}:destination"
                , "2"
                , "{same}:one"
                , "{same}:two"
                , "WEIGHTS"
                , "1"
                , "2"
                , "AGGREGATE"
                , "MAX"
                ]
                "{same}:destination"
            shouldReject
                "ZUNIONSTORE"
                ["destination", "2", "one", "two"]
                "CROSSSLOT Keys in request don't hash to the same slot"
            shouldReject
                "ZUNIONSTORE"
                ["{same}:destination", "1", "{same}:one", "garbage"]
                "ZUNIONSTORE has malformed key arguments"

        it "validates GEORADIUS units and STORE destinations case-insensitively" $ do
            shouldRouteBy
                "GEORADIUS"
                ["{same}:source", "0", "0", "1", "km"]
                "{same}:source"
            shouldRouteBy
                "GEORADIUS"
                ["{same}:source", "0", "0", "1", "KM", "sToRe", "{same}:destination"]
                "{same}:source"
            shouldRouteBy
                "GEORADIUS"
                ["key", ".5", "1.", "0x1p2", "km"]
                "key"
            shouldReject
                "GEORADIUS"
                ["key", "0", "0", "1", "yards"]
                "GEORADIUS has malformed arguments"
            shouldReject
                "GEORADIUS"
                ["key", "0", "0", "1", "km", "STORE"]
                "GEORADIUS has malformed arguments"
            shouldReject
                "GEORADIUS"
                ["key", "0", "0", "1e9999", "km"]
                "GEORADIUS has malformed arguments"
            shouldReject
                "GEORADIUS"
                ["key", "0", "0", "nan", "km"]
                "GEORADIUS has malformed arguments"

        it "validates XREAD mandatory STREAMS and stream/ID balance" $ do
            shouldRouteBy
                "XREAD"
                ["COUNT", "1", "STREAMS", "{same}:one", "{same}:two", "0-0", "0-0"]
                "{same}:one"
            shouldReject "XREAD" ["COUNT", "1", "NOSTREAMS"] "XREAD requires STREAMS"
            shouldReject
                "XREAD"
                ["STREAMS", "key", "0-0", "another"]
                "XREAD has malformed key arguments"

        it "validates XREADGROUP GROUP and STREAMS structural tokens" $ do
            shouldRouteBy
                "XREADGROUP"
                ["GROUP", "group", "consumer", "STREAMS", "{same}:one", ">"]
                "{same}:one"
            shouldReject
                "XREADGROUP"
                ["WRONG", "group", "consumer", "STREAMS", "key", ">"]
                "XREADGROUP has malformed arguments"
            shouldReject
                "XREADGROUP"
                ["GROUP", "group", "consumer", "NOSTREAMS", "key", ">"]
                "XREADGROUP requires STREAMS"

        it "supports fixed MIGRATE and fails closed only for selected dynamic KEYS" $ do
            shouldRouteBy
                "MIGRATE"
                ["host", "6379", "{same}:key", "0", "1000"]
                "{same}:key"
            shouldReject
                "MIGRATE"
                ["host", "6379", "", "0", "1000", "KEYS", "key"]
                "MIGRATE uses an unsupported dynamic key specification"
            shouldReject
                "MIGRATE"
                ["host", "6379", "", "0", "1000"]
                "MIGRATE has malformed key arguments"

        it "supports static SORT and fails closed when dynamic key forms are selected" $ do
            shouldRouteBy "SORT" ["key"] "key"
            shouldRouteBy "SORT_RO" ["key", "LIMIT", "0", "10", "DESC"] "key"
            shouldReject
                "SORT"
                ["key", "BY", "pattern"]
                "SORT uses an unsupported dynamic key specification"
            shouldReject
                "SORT"
                ["key", "STORE", "destination"]
                "SORT uses an unsupported dynamic key specification"

        it "resolves hyphenated subcommands and rejects unknown subcommands" $ do
            shouldRouteKeyless "CONFIG" ["GET", "timeout"]
            shouldRouteKeyless "CLIENT" ["NO-EVICT", "ON"]
            shouldRouteKeyless "CLUSTER" ["SET-CONFIG-EPOCH", "1"]
            shouldReject
                "CONFIG"
                ["NOT-A-SUBCOMMAND"]
                "unknown subcommand for CONFIG"

        it "parses repeated-token argument blocks from generated metadata" $ do
            shouldRouteKeyless
                "CLIENT"
                ["TRACKING", "ON", "PREFIX", "one", "PREFIX", "two"]
            shouldRouteBy
                "BITFIELD_RO"
                ["key", "GET", "i8", "0", "GET", "i8", "1"]
                "key"

        it "treats valid keyless commands as keyless and rejects unknown commands" $ do
            shouldRouteKeyless "PING" ["payload"]
            shouldReject "DOESNOTEXIST" ["key"] "unknown command"

        it "covers every generated command without exposing internal metadata" $ do
            length (keylessCommands ++ requiresKeyCommands) `shouldBe` 392

shouldRouteBy :: BS.ByteString -> [BS.ByteString] -> BS.ByteString -> Expectation
shouldRouteBy command arguments expected =
    case classifyCommand command arguments of
        KeyedRoute actual -> actual `shouldBe` expected
        KeylessRoute -> expectationFailure "expected keyed route, got keyless route"
        CommandError message ->
            expectationFailure $ "expected keyed route, got error: " ++ message

shouldRouteKeyless :: BS.ByteString -> [BS.ByteString] -> Expectation
shouldRouteKeyless command arguments =
    case classifyCommand command arguments of
        KeylessRoute -> pure ()
        KeyedRoute _ -> expectationFailure "expected keyless route, got keyed route"
        CommandError message ->
            expectationFailure $ "expected keyless route, got error: " ++ message

shouldReject :: BS.ByteString -> [BS.ByteString] -> String -> Expectation
shouldReject command arguments expected =
    case classifyCommand command arguments of
        CommandError actual -> actual `shouldBe` expected
        KeylessRoute -> expectationFailure "expected command error, got keyless route"
        KeyedRoute _ -> expectationFailure "expected command error, got keyed route"
