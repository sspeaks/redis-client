{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Exception               (evaluate)
import qualified Data.ByteString                 as BS
import           Database.Redis.Cluster          (calculateSlot)
import           Database.Redis.Cluster.Commands (CommandRouting (..),
                                                  classifyCommand,
                                                  keylessCommands,
                                                  requiresKeyCommands)
import           System.Timeout                  (timeout)
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

        it "accepts Redis unordered options and rejects duplicate options" $ do
            shouldRouteBy "SET" ["{same}:key", "value", "EX", "10", "NX"] "{same}:key"
            shouldRouteBy "SET" ["{same}:key", "value", "NX", "PX", "10", "GET"] "{same}:key"
            shouldRouteBy
                "GEORADIUS"
                ["{same}:key", "0", "0", "1", "km", "DESC", "WITHDIST", "COUNT", "1"]
                "{same}:key"
            shouldRejectAny "SET" ["key", "value", "NX", "NX"]
            shouldRejectAny "GEORADIUS" ["key", "0", "0", "1", "km", "DESC", "DESC"]

        it "uses Redis string2ll decimal syntax for integer and key-count fields" $ do
            shouldRouteBy
                "EVAL"
                ["return 1", "1", "{same}:key"]
                "{same}:key"
            mapM_
                (\count -> shouldRejectAny "EVAL" ["return 1", count, "{same}:key"])
                [ " 1"
                , "1 "
                , "+1"
                , "01"
                , "-01"
                , "0x1"
                , "1x"
                , "9223372036854775808"
                , "-9223372036854775809"
                ]
            shouldRouteBy
                "MIGRATE"
                ["host", "6379", "{same}:key", "0", "1000"]
                "{same}:key"
            mapM_
                (\port -> shouldRejectAny "MIGRATE" ["host", port, "key", "0", "1000"])
                ["+6379", "06379", "6379 ", "0x18eb", "6379x"]

        it "matches Redis 7.2 string2ll for the complete signed Int64 edge corpus" $
            mapM_
                (\(value, expected) -> acceptsRedisInteger value `shouldBe` expected)
                string2llCorpus

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

        it "accepts XREAD option permutations and bounded large paired lists" $ do
            shouldRouteBy
                "XREAD"
                ["BLOCK", "0", "COUNT", "1", "STREAMS", "{same}:one", "0-0"]
                "{same}:one"
            shouldRouteBy
                "XREADGROUP"
                ["GROUP", "group", "consumer", "NOACK", "BLOCK", "0", "COUNT", "1", "STREAMS", "{same}:one", ">"]
                "{same}:one"
            shouldRejectAny "XREAD" ["COUNT", "1", "COUNT", "2", "STREAMS", "key", "0-0"]
            shouldRejectAny "XREADGROUP" ["GROUP", "g", "c", "NOACK", "NOACK", "STREAMS", "key", ">"]
            let streamCount = 4096
                streams = ["{same}:" <> decimal index | index <- [1 .. streamCount]]
                arguments = ["BLOCK", "0", "COUNT", "1", "STREAMS"] <> streams <> replicate streamCount "0-0"
            result <- timeout 5000000 (evaluate (classifyCommand "XREAD" arguments))
            case result of
                Just (KeyedRoute key) -> key `shouldBe` "{same}:1"
                Just _ -> expectationFailure "expected keyed route for balanced XREAD lists"
                Nothing -> expectationFailure "large XREAD grammar parse exceeded five seconds"
            shouldRejectAny "XREAD" (replicate 65537 "x")

        it "completes near-cap repeated-key and repeated-scalar parses within ten seconds" $ do
            let keyCount = 65535
                memberCount = 65534
            shouldCompleteWithin "MGET" (replicate keyCount "{same}:key")
            shouldCompleteWithin "DEL" (replicate keyCount "{same}:key")
            shouldCompleteWithin
                "SADD"
                ("{same}:key" : replicate memberCount "member")

        it "accepts empty, one, and many terminal optional repeated scalars" $ do
            shouldRouteKeyless "COMMAND" ["DOCS"]
            shouldRouteKeyless "COMMAND" ["DOCS", "GET"]
            shouldRouteKeyless "COMMAND" ["DOCS", "GET", "SET", "MGET"]
            shouldRouteKeyless "ACL" ["SETUSER", "profile-user"]
            shouldRouteKeyless "ACL" ["SETUSER", "profile-user", "on"]
            shouldRouteKeyless
                "ACL"
                ["SETUSER", "profile-user", "on", ">password", "+get"]
            shouldRouteKeyless "PUNSUBSCRIBE" []
            shouldRouteKeyless "PUNSUBSCRIBE" ["channel*"]
            shouldRouteKeyless "PUNSUBSCRIBE" ["one*", "two*", "three*"]
            shouldRouteBy "GEOHASH" ["{same}:key"] "{same}:key"
            shouldRouteBy "GEOHASH" ["{same}:key", "member"] "{same}:key"
            shouldRouteBy
                "GEOHASH"
                ["{same}:key", "one", "two", "three"]
                "{same}:key"

        it "completes near-cap terminal optional repeats within ten seconds" $ do
            shouldCompleteKeylessWithin
                "COMMAND"
                ("DOCS" : replicate 65534 "GET")
            shouldCompleteKeylessWithin
                "ACL"
                (["SETUSER", "profile-user"] <> replicate 65533 "on")
            shouldCompleteKeylessWithin
                "PUNSUBSCRIBE"
                (replicate 65535 "channel*")
            shouldCompleteWithin
                "GEOHASH"
                ("{same}:key" : replicate 65534 "member")

        it "fails closed above the parser frame cap within ten seconds" $ do
            shouldRejectWithin "MGET" (replicate 65536 "{same}:key")
            shouldRejectWithin "DEL" (replicate 65536 "{same}:key")
            shouldRejectWithin
                "SADD"
                ("{same}:key" : replicate 65535 "member")
            shouldRejectWithin
                "COMMAND"
                ("DOCS" : replicate 65535 "GET")
            shouldRejectWithin
                "ACL"
                (["SETUSER", "profile-user"] <> replicate 65534 "on")
            shouldRejectWithin
                "PUNSUBSCRIBE"
                (replicate 65536 "channel*")
            shouldRejectWithin
                "GEOHASH"
                ("{same}:key" : replicate 65535 "member")

        it "bounds over-cap traversal before vector conversion" $ do
            shouldRejectWithin "MGET" (repeat "{same}:key")
            let poisonedTail =
                    replicate 65535 "{same}:key"
                        <> (error "over-cap element was forced" : error "over-cap tail was traversed")
            shouldRejectWithin "MGET" poisonedTail

        it "preserves bounded MGET, DEL, and XREAD parsing" $ do
            shouldRouteBy "MGET" ["{same}:one", "{same}:two"] "{same}:one"
            shouldRouteBy "DEL" ["{same}:one", "{same}:two"] "{same}:one"
            shouldRouteBy
                "XREAD"
                ["COUNT", "1", "STREAMS", "{same}:one", "{same}:two", "0-0", "0-0"]
                "{same}:one"

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
            shouldRouteKeyless
                "CLIENT"
                ["TRACKING", "ON", "PREFIX", "one", "NOLOOP", "PREFIX", "two"]
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

shouldRejectAny :: BS.ByteString -> [BS.ByteString] -> Expectation
shouldRejectAny command arguments =
    case classifyCommand command arguments of
        CommandError _ -> pure ()
        KeylessRoute -> expectationFailure "expected command error, got keyless route"
        KeyedRoute _ -> expectationFailure "expected command error, got keyed route"

acceptsRedisInteger :: BS.ByteString -> Bool
acceptsRedisInteger value =
    case classifyCommand "SET" ["{same}:key", "value", "EX", value] of
        KeyedRoute _   -> True
        KeylessRoute   -> False
        CommandError _ -> False

string2llCorpus :: [(BS.ByteString, Bool)]
string2llCorpus =
    [ ("", False)
    , ("-", False)
    , ("+", False)
    , ("--1", False)
    , ("+-1", False)
    , ("-+1", False)
    , ("0", True)
    , ("-0", False)
    , ("00", False)
    , ("01", False)
    , ("-00", False)
    , ("-01", False)
    , ("1", True)
    , ("-1", True)
    , (" 1", False)
    , ("1 ", False)
    , ("\t1", False)
    , ("1\t", False)
    , ("1\n", False)
    , ("1 0", False)
    , ("0x1", False)
    , ("0X1", False)
    , ("-0x1", False)
    , ("1x", False)
    , ("-1x", False)
    , ("1.0", False)
    , ("1\NUL", False)
    , ("1-", False)
    , ("9223372036854775807", True)
    , ("-9223372036854775808", True)
    , ("9223372036854775808", False)
    , ("-9223372036854775809", False)
    , ("18446744073709551615", False)
    , ("-18446744073709551616", False)
    , (BS.replicate 256 57, False)
    , ("-" <> BS.replicate 256 57, False)
    , (BS.replicate 256 48, False)
    , (BS.pack [0], False)
    , (BS.pack [128], False)
    , (BS.pack [255], False)
    , (BS.pack [49, 128], False)
    , (BS.pack [45, 49, 255], False)
    ]

shouldCompleteWithin :: BS.ByteString -> [BS.ByteString] -> Expectation
shouldCompleteWithin command arguments = do
    result <- timeout 10000000 (evaluate $ classifyCommand command arguments)
    case result of
        Just (KeyedRoute key) -> key `shouldBe` "{same}:key"
        Just KeylessRoute -> expectationFailure "expected keyed route, got keyless route"
        Just (CommandError message) ->
            expectationFailure $ "expected keyed route, got error: " ++ message
        Nothing -> expectationFailure "near-cap grammar parse exceeded ten seconds"

shouldCompleteKeylessWithin :: BS.ByteString -> [BS.ByteString] -> Expectation
shouldCompleteKeylessWithin command arguments = do
    result <- timeout 10000000 (evaluate $ classifyCommand command arguments)
    case result of
        Just KeylessRoute -> pure ()
        Just (KeyedRoute _) -> expectationFailure "expected keyless route, got keyed route"
        Just (CommandError message) ->
            expectationFailure $ "expected keyless route, got error: " ++ message
        Nothing -> expectationFailure "near-cap grammar parse exceeded ten seconds"

shouldRejectWithin :: BS.ByteString -> [BS.ByteString] -> Expectation
shouldRejectWithin command arguments = do
    result <- timeout 10000000 (evaluate $ classifyCommand command arguments)
    case result of
        Just (CommandError _) -> pure ()
        Just KeylessRoute -> expectationFailure "expected command error, got keyless route"
        Just (KeyedRoute _) -> expectationFailure "expected command error, got keyed route"
        Nothing -> expectationFailure "over-cap grammar parse exceeded ten seconds"

decimal :: Int -> BS.ByteString
decimal = BS.pack . fmap (fromIntegral . fromEnum) . show
