{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Client                     (Client (..), PlainTextClient)
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (IOException, evaluate, finally,
                                             try)
import           Control.Monad              (void)
import qualified Control.Monad.State        as State
import           Data.Attoparsec.ByteString (parseOnly)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Builder    as Builder
import qualified Data.ByteString.Lazy.Char8 as BSC
import           Data.List                  (foldl', isInfixOf)
import           RedisCommandClient         (ClientState (..),
                                             GeoRadiusFlag (..),
                                             GeoSearchBy (..),
                                             GeoSearchFrom (..),
                                             GeoSearchOption (..), GeoUnit (..),
                                             RedisCommandClient,
                                             RedisCommands (..), RunState (..),
                                             parseManyWith,
                                             runCommandsAgainstPlaintextHost)
import           Resp                       (Encodable (encode), RespData (..),
                                             parseRespData)
import           System.Directory           (doesFileExist, findExecutable)
import           System.Environment         (getEnvironment, getExecutablePath)
import           System.Exit                (ExitCode (..))
import           System.FilePath            (takeDirectory, (</>))
import           System.IO                  (BufferMode (LineBuffering), Handle,
                                             hClose, hFlush, hGetContents,
                                             hGetLine, hPutStrLn,
                                             hIsTerminalDevice, hSetBuffering,
                                             isEOF, stdin, stdout)
import           System.Process             (CreateProcess (..),
                                             ProcessHandle,
                                             StdStream (CreatePipe), proc,
                                             getProcessExitCode,
                                             readCreateProcessWithExitCode,
                                             terminateProcess, waitForProcess,
                                             withCreateProcess)
import           System.Timeout             (timeout)
import           Test.Hspec                 (beforeAll_, before_, describe,
                                             expectationFailure, hspec, it,
                                             shouldBe, shouldNotBe,
                                             shouldReturn, shouldSatisfy)

runRedisAction :: RedisCommandClient PlainTextClient a -> IO a
runRedisAction = runCommandsAgainstPlaintextHost (RunState 
  { host = "redis.local"
  , port = Nothing
  , username = "default"
  , password = ""
  , useTLS = False
  , dataGBs = 0
  , flush = False
  , serial = False
  , numConnections = Nothing
  , useCluster = False
  , tunnelMode = "smart"
  , keySize = 512
  , valueSize = 512
  })

getRedisClientPath :: IO FilePath
getRedisClientPath = do
  execPath <- getExecutablePath
  let binDir = takeDirectory execPath
      sibling = binDir </> "redis-client"
  siblingExists <- doesFileExist sibling
  if siblingExists
    then return sibling
    else do
      found <- findExecutable "redis-client"
      case found of
        Just path -> return path
        Nothing -> error $ "Could not locate redis-client executable starting from " <> binDir

cleanupProcess :: ProcessHandle -> IO ()
cleanupProcess ph = do
  _ <- (try (terminateProcess ph) :: IO (Either IOException ()))
  _ <- (try (waitForProcess ph) :: IO (Either IOException ExitCode))
  pure ()

waitForSubstring :: Handle -> String -> IO ()
waitForSubstring handle needle = do
  line <- hGetLine handle
  if needle `isInfixOf` line
    then pure ()
    else waitForSubstring handle needle

drainHandle :: Handle -> IO String
drainHandle handle = do
  result <- try (hGetContents handle) :: IO (Either IOException String)
  case result of
    Left _ -> pure ""
    Right contents -> do
      void $ evaluate (length contents)
      pure contents

main :: IO ()
main = do
  redisClient <- getRedisClientPath
  baseEnv <- getEnvironment
  let tlsExtras = [("SSL_CERT_FILE", "/certs/redis-ca.crt"), ("REDIS_CLIENT_TLS_INSECURE", "1")]
      mergeEnv extra =
        let combined = tlsExtras ++ extra
            filteredBase = filter (\(k, _) -> k `notElem` map fst combined) baseEnv
         in combined ++ filteredBase
      runRedisClient args input =
        readCreateProcessWithExitCode ((proc redisClient args) {env = Just (mergeEnv [])}) input
      runRedisClientWithEnv extra args input =
        readCreateProcessWithExitCode ((proc redisClient args) {env = Just (mergeEnv extra)}) input
      chunkKilosForTest :: Integer
      chunkKilosForTest = 4
  hspec $ do
    before_ (void $ runRedisAction flushAll) $ do
      describe "Can run basic operations: " $ do
        it "get and set are encoded and respond properly" $ do
          runRedisAction (set "hello" "world") `shouldReturn` RespSimpleString "OK"
          runRedisAction (get "hello") `shouldReturn` RespBulkString "world"
        it "ping is encoded properly and returns pong" $ do
          runRedisAction ping `shouldReturn` RespSimpleString "PONG"
        it "auth negotiates the RESP3 handshake" $ do
          authResp <- runRedisAction (auth "default" "")
          case authResp of
            RespError err -> expectationFailure $ "Unexpected AUTH error: " <> err
            RespMap _ -> pure ()
            RespArray _ -> pure ()
            RespSimpleString "OK" -> pure ()
            _ -> expectationFailure $ "Unexpected AUTH response shape: " <> show authResp
        it "bulkSet is encoded properly and subsequent gets work properly" $ do
          runRedisAction (bulkSet [("a", "b"), ("c", "d"), ("e", "f")]) `shouldReturn` RespSimpleString "OK"
          runRedisAction (get "a") `shouldReturn` RespBulkString "b"
          runRedisAction (get "c") `shouldReturn` RespBulkString "d"
          runRedisAction (get "e") `shouldReturn` RespBulkString "f"
        it "mget is encoded properly and returns multiple values" $ do
          runRedisAction (set "mget:key1" "value1") `shouldReturn` RespSimpleString "OK"
          runRedisAction (set "mget:key2" "value2") `shouldReturn` RespSimpleString "OK"
          runRedisAction (mget ["mget:key1", "mget:key2", "mget:missing"]) `shouldReturn`
            RespArray [RespBulkString "value1", RespBulkString "value2", RespNullBilkString]
        it "del is encoded properly and deletes the key" $ do
          runRedisAction (set "testKey" "testValue") `shouldReturn` RespSimpleString "OK"
          runRedisAction (del ["testKey"]) `shouldReturn` RespInteger 1
          runRedisAction (get "testKey") `shouldReturn` RespNullBilkString
        it "exists is encoded properly and checks if the key exists" $ do
          runRedisAction (set "testKey" "testValue") `shouldReturn` RespSimpleString "OK"
          runRedisAction (exists ["testKey"]) `shouldReturn` RespInteger 1
          runRedisAction (del ["testKey"]) `shouldReturn` RespInteger 1
          runRedisAction (exists ["testKey"]) `shouldReturn` RespInteger 0
        it "dbsize reflects the number of keys" $ do
          runRedisAction dbsize `shouldReturn` RespInteger 0
          runRedisAction (set "dbsize:key" "value") `shouldReturn` RespSimpleString "OK"
          runRedisAction dbsize `shouldReturn` RespInteger 1
        it "incr is encoded properly and increments the key" $ do
          runRedisAction (set "counter" "0") `shouldReturn` RespSimpleString "OK"
          runRedisAction (incr "counter") `shouldReturn` RespInteger 1
          runRedisAction (get "counter") `shouldReturn` RespBulkString "1"
        it "decr is encoded properly and decrements the key" $ do
          runRedisAction (set "counter:down" "5") `shouldReturn` RespSimpleString "OK"
          runRedisAction (decr "counter:down") `shouldReturn` RespInteger 4
          runRedisAction (get "counter:down") `shouldReturn` RespBulkString "4"
        it "psetex sets value with expiry" $ do
          runRedisAction (psetex "psetex:key" 600 "value") `shouldReturn` RespSimpleString "OK"
          runRedisAction (get "psetex:key") `shouldReturn` RespBulkString "value"
        it "setnx is encoded properly and only sets when a key is missing" $ do
          runRedisAction (setnx "nx:key" "first") `shouldReturn` RespInteger 1
          runRedisAction (setnx "nx:key" "second") `shouldReturn` RespInteger 0
          runRedisAction (get "nx:key") `shouldReturn` RespBulkString "first"
        it "clientSetInfo updates client metadata" $ do
          runRedisAction (clientSetInfo ["LIB-NAME", "redis-client-e2e"]) `shouldReturn` RespSimpleString "OK"
          runRedisAction (clientSetInfo ["LIB-VER", "0.1-test"]) `shouldReturn` RespSimpleString "OK"
        it "hset and hget are encoded properly and work correctly" $ do
          runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
          runRedisAction (hget "myhash" "field1") `shouldReturn` RespBulkString "value1"
        it "hmget returns multiple hash fields" $ do
          runRedisAction (hset "hash:multi" "field1" "value1") `shouldReturn` RespInteger 1
          runRedisAction (hset "hash:multi" "field2" "value2") `shouldReturn` RespInteger 1
          runRedisAction (hmget "hash:multi" ["field1", "field2", "missing"]) `shouldReturn`
            RespArray [RespBulkString "value1", RespBulkString "value2", RespNullBilkString]
        it "hexists indicates whether a hash field exists" $ do
          runRedisAction (hset "hash:exists" "field" "value") `shouldReturn` RespInteger 1
          runRedisAction (hexists "hash:exists" "field") `shouldReturn` RespInteger 1
          runRedisAction (hexists "hash:exists" "missing") `shouldReturn` RespInteger 0
        it "lpush and lrange are encoded properly and work correctly" $ do
          runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (lrange "mylist" 0 2) `shouldReturn` RespArray [RespBulkString "three", RespBulkString "two", RespBulkString "one"]
        it "expire and ttl are encoded properly and work correctly" $ do
          runRedisAction (set "mykey" "myvalue") `shouldReturn` RespSimpleString "OK"
          runRedisAction (expire "mykey" 10) `shouldReturn` RespInteger 1
          runRedisAction (ttl "mykey") `shouldReturn` RespInteger 10
        it "rpush and lpop are encoded properly and work correctly" $ do
          runRedisAction (rpush "mylist2" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (lpop "mylist2") `shouldReturn` RespBulkString "one"
        it "rpop is encoded properly and works correctly" $ do
          runRedisAction (rpush "mylist3" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (rpop "mylist3") `shouldReturn` RespBulkString "three"
        it "sadd and smembers are encoded properly and work correctly" $ do
          runRedisAction (sadd "myset" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (smembers "myset") `shouldReturn` RespArray [RespBulkString "one", RespBulkString "two", RespBulkString "three"]
        it "scard returns the set cardinality" $ do
          runRedisAction (sadd "size:set" ["a", "b", "c"]) `shouldReturn` RespInteger 3
          runRedisAction (scard "size:set") `shouldReturn` RespInteger 3
        it "sismember detects membership" $ do
          runRedisAction (sadd "member:set" ["alpha"]) `shouldReturn` RespInteger 1
          runRedisAction (sismember "member:set" "alpha") `shouldReturn` RespInteger 1
          runRedisAction (sismember "member:set" "beta") `shouldReturn` RespInteger 0
        it "hdel is encoded properly and works correctly" $ do
          runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
          runRedisAction (hdel "myhash" ["field1"]) `shouldReturn` RespInteger 1
          runRedisAction (hget "myhash" "field1") `shouldReturn` RespNullBilkString
        it "hkeys is encoded properly and works correctly" $ do
          runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
          runRedisAction (hset "myhash" "field2" "value2") `shouldReturn` RespInteger 1
          runRedisAction (hkeys "myhash") `shouldReturn` RespArray [RespBulkString "field1", RespBulkString "field2"]
        it "hvals is encoded properly and works correctly" $ do
          runRedisAction (hset "myhash" "field1" "value1") `shouldReturn` RespInteger 1
          runRedisAction (hset "myhash" "field2" "value2") `shouldReturn` RespInteger 1
          runRedisAction (hvals "myhash") `shouldReturn` RespArray [RespBulkString "value1", RespBulkString "value2"]
        it "llen is encoded properly and works correctly" $ do
          runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (llen "mylist") `shouldReturn` RespInteger 3
        it "lindex is encoded properly and works correctly" $ do
          runRedisAction (lpush "mylist" ["one", "two", "three"]) `shouldReturn` RespInteger 3
          runRedisAction (lindex "mylist" 1) `shouldReturn` RespBulkString "two"
        it "zadd and zrange are encoded properly and work correctly" $ do
          runRedisAction (zadd "myzset" [(1, "one"), (2, "two"), (3, "three")]) `shouldReturn` RespInteger 3
          runRedisAction (zrange "myzset" 0 1 False) `shouldReturn` RespArray [RespBulkString "one", RespBulkString "two"]
          runRedisAction (zrange "myzset" 0 (-1) True)
            `shouldReturn` RespArray
              [ RespBulkString "one",
                RespBulkString "1",
                RespBulkString "two",
                RespBulkString "2",
                RespBulkString "three",
                RespBulkString "3"
              ]

        it "geoadd and geodist work correctly" $ do
          runRedisAction (geoadd "geo:italy" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          runRedisAction (geodist "geo:italy" "Palermo" "Catania" (Just Kilometers)) `shouldReturn` RespBulkString "166.2742"

        it "geohash returns geohash strings for members" $ do
          runRedisAction (geoadd "geo:hash" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          runRedisAction (geohash "geo:hash" ["Palermo", "Catania"]) `shouldReturn`
            RespArray [RespBulkString "sqc8b49rny0", RespBulkString "sqdtr74hyu0"]

        it "geopos returns longitudes and latitudes" $ do
          runRedisAction (geoadd "geo:pos" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          response <- runRedisAction (geopos "geo:pos" ["Palermo", "Catania"])
          case response of
            RespArray [RespArray [RespBulkString lon1, RespBulkString lat1], RespArray [RespBulkString lon2, RespBulkString lat2]] -> do
              lon1 `shouldSatisfy` (BSC.isPrefixOf "13.36")
              lat1 `shouldSatisfy` (BSC.isPrefixOf "38.11")
              lon2 `shouldSatisfy` (BSC.isPrefixOf "15.08")
              lat2 `shouldSatisfy` (BSC.isPrefixOf "37.50")
            _ -> expectationFailure $ "Unexpected GEOPOS response: " <> show response

        it "georadius returns members ordered with distances" $ do
          runRedisAction (geoadd "geo:radius" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          radiusResult <- runRedisAction (georadius "geo:radius" 15 37 200 Kilometers [GeoWithDist, GeoRadiusAsc])
          case radiusResult of
            RespArray [RespArray [RespBulkString "Catania", RespBulkString dist1], RespArray [RespBulkString "Palermo", RespBulkString dist2]] -> do
              dist1 `shouldSatisfy` (not . BSC.null)
              dist2 `shouldSatisfy` (not . BSC.null)
            _ -> expectationFailure $ "Unexpected GEORADIUS response: " <> show radiusResult

        it "georadiusRo reads data with distance flags" $ do
          runRedisAction (geoadd "geo:radius-ro" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          roResult <- runRedisAction (georadiusRo "geo:radius-ro" 15 37 200 Kilometers [GeoWithDist, GeoRadiusAsc])
          case roResult of
            RespArray [RespArray [RespBulkString "Catania", RespBulkString dist1], RespArray [RespBulkString "Palermo", RespBulkString dist2]] -> do
              dist1 `shouldSatisfy` (not . BSC.null)
              dist2 `shouldSatisfy` (not . BSC.null)
            _ -> expectationFailure $ "Unexpected GEORADIUS_RO response: " <> show roResult

        it "georadiusByMember returns nearby members" $ do
          runRedisAction (geoadd "geo:member" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          byMember <- runRedisAction (georadiusByMember "geo:member" "Palermo" 200 Kilometers [GeoWithDist, GeoRadiusAsc])
          case byMember of
            RespArray [RespArray [RespBulkString "Palermo"], RespArray [RespBulkString "Catania", RespBulkString dist]] -> do
              dist `shouldSatisfy` (not . BSC.null)
            RespArray [RespArray [RespBulkString "Palermo", RespBulkString distSelf], RespArray [RespBulkString "Catania", RespBulkString distOther]] -> do
              distSelf `shouldSatisfy` (not . BSC.null)
              distOther `shouldSatisfy` (not . BSC.null)
            _ -> expectationFailure $ "Unexpected GEORADIUSBYMEMBER response: " <> show byMember

        it "georadiusByMemberRo reads without mutating state" $ do
          runRedisAction (geoadd "geo:member-ro" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          byMemberRo <- runRedisAction (georadiusByMemberRo "geo:member-ro" "Palermo" 200 Kilometers [GeoWithDist, GeoRadiusAsc])
          case byMemberRo of
            RespArray [RespArray [RespBulkString "Palermo"], RespArray [RespBulkString "Catania", RespBulkString dist]] -> do
              dist `shouldSatisfy` (not . BSC.null)
            RespArray [RespArray [RespBulkString "Palermo", RespBulkString distSelf], RespArray [RespBulkString "Catania", RespBulkString distOther]] -> do
              distSelf `shouldSatisfy` (not . BSC.null)
              distOther `shouldSatisfy` (not . BSC.null)
            _ -> expectationFailure $ "Unexpected GEORADIUSBYMEMBER_RO response: " <> show byMemberRo

        it "geosearch and geosearchstore integrate with sorted sets" $ do
          runRedisAction (geoadd "geo:search" [(13.361389, 38.115556, "Palermo"), (15.087269, 37.502669, "Catania")]) `shouldReturn` RespInteger 2
          runRedisAction (geosearch "geo:search" (GeoFromLonLat 15 37) (GeoByRadius 200 Kilometers) [GeoSearchAsc])
            `shouldReturn` RespArray [RespBulkString "Catania", RespBulkString "Palermo"]
          runRedisAction (geosearchstore "geo:dest" "geo:search" (GeoFromLonLat 15 37) (GeoByRadius 200 Kilometers) [GeoSearchAsc] True)
            `shouldReturn` RespInteger 2
          storeResult <- runRedisAction (zrange "geo:dest" 0 (-1) True)
          case storeResult of
            RespArray [RespBulkString member1, _, RespBulkString member2, _] -> do
              member1 `shouldBe` "Catania"
              member2 `shouldBe` "Palermo"
            _ -> expectationFailure $ "Unexpected GEOSEARCHSTORE ZRANGE response: " <> show storeResult

      describe "Pipelining works: " $ do
        it "can pipeline 100 commands and retrieve their values" $ do
          runRedisAction
            ( do
                ClientState client _ <- State.get
                send client $ mconcat ([Builder.toLazyByteString . encode . RespArray $ map RespBulkString ["SET", "KEY" <> BSC.pack (show n), "VALUE" <> BSC.pack (show n)] | n <- [1 .. 100]])
                parseManyWith 100 (receive client)
            )
            `shouldReturn` replicate 100 (RespSimpleString "OK")
          runRedisAction
            ( do
                ClientState client _ <- State.get
                send client $ mconcat ([Builder.toLazyByteString . encode . RespArray $ map RespBulkString ["GET", "KEY" <> BSC.pack (show n)] | n <- [1 .. 100]])
                parseManyWith 100 (receive client)
            )
            `shouldReturn` [RespBulkString ("VALUE" <> BSC.pack (show n)) | n <- [1 .. 100]]
    describe "redis-client modes" $ beforeAll_ (void $ runRedisAction flushAll) $ do
      it "fill --data 1 writes expected number of keys" $ do
        (code, stdoutOut, _) <- runRedisClientWithEnv [("REDIS_CLIENT_FILL_CHUNK_KB", show chunkKilosForTest)] ["fill", "--host", "redis.local", "--data", "1"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("Filling cache" `isInfixOf`)
        runRedisAction dbsize `shouldReturn` RespInteger 1048576

      it "fill --flush clears the database" $ do
        threadDelay 200000
        runRedisAction dbsize `shouldReturn` RespInteger 1048576
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--flush"] ""
        code `shouldNotBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("Flushing cache" `isInfixOf`)
        runRedisAction dbsize `shouldReturn` RespInteger 0

      it "fill with --key-size 128 creates keys of correct size" $ do
        void $ runRedisAction flushAll
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "128"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("key size: 128 bytes" `isInfixOf`)
        -- Verify some keys exist
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> n `shouldSatisfy` (> 0)
          _ -> expectationFailure "Expected integer response from DBSIZE"
        -- Verify a random key has the expected size (128 bytes) by retrieving it
        keyResp <- runRedisAction (do
            ClientState client _ <- State.get
            send client $ Builder.toLazyByteString $ encode $ RespArray [RespBulkString "RANDOMKEY"]
            receive client >>= \bs -> do
              ClientState _ buffer <- State.get
              case parseOnly parseRespData (buffer <> bs) of
                Right resp -> do
                  State.put (ClientState client BS.empty)
                  return resp
                Left err -> error $ "Parse error: " ++ err)
        case keyResp of
          RespBulkString key -> fromIntegral (BSC.length key) `shouldBe` (128 :: Int)
          _ -> expectationFailure "Expected bulk string response from RANDOMKEY"

      it "fill with --key-size 64 creates smaller keys" $ do
        void $ runRedisAction flushAll
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "64"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("key size: 64 bytes" `isInfixOf`)

      it "fill with --key-size 2048 creates larger keys" $ do
        void $ runRedisAction flushAll
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "2048"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("key size: 2048 bytes" `isInfixOf`)

      it "fill rejects invalid --key-size values" $ do
        (code1, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "0"] ""
        code1 `shouldNotBe` ExitSuccess
        (code2, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "100000"] ""
        code2 `shouldNotBe` ExitSuccess

      it "fill with --key-size 128 fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "128"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=128, bytesPerCommand = 128 + 512 = 640 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 640) = 1,677,722 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 1677722
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --key-size 64 fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "64"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=64, bytesPerCommand = 64 + 512 = 576 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 576) = 1,864,128 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 1864128
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --key-size 256 fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "256"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=256, bytesPerCommand = 256 + 512 = 768 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 768) = 1,398,102 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 1398102
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --key-size 512 fills accurate memory (1GB, backward compatible)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "512"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=512, bytesPerCommand = 512 + 512 = 1024 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: 1,073,741,824 / 1024 = 1,048,576 keys (exact)
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 1048576
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --value-size 128 creates values of correct size" $ do
        void $ runRedisAction flushAll
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "512", "--value-size", "128"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("value size: 128 bytes" `isInfixOf`)
        -- Verify some keys exist
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> n `shouldSatisfy` (> 0)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --value-size 2048 creates larger values" $ do
        void $ runRedisAction flushAll
        (code, stdoutOut, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "512", "--value-size", "2048"] ""
        code `shouldBe` ExitSuccess
        stdoutOut `shouldSatisfy` ("value size: 2048 bytes" `isInfixOf`)

      it "fill rejects invalid --value-size values" $ do
        (code1, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--value-size", "0"] ""
        code1 `shouldNotBe` ExitSuccess
        (code2, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--value-size", "600000"] ""
        code2 `shouldNotBe` ExitSuccess

      it "fill with --value-size 1024 fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "512", "--value-size", "1024"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=512, valueSize=1024, bytesPerCommand = 512 + 1024 = 1536 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 1536) = 698,880 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 698880
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with --value-size 8192 fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "512", "--value-size", "8192"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=512, valueSize=8192, bytesPerCommand = 512 + 8192 = 8704 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 8704) = 123,362 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 123362
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "fill with custom --key-size and --value-size fills accurate memory (1GB)" $ do
        void $ runRedisAction flushAll
        (code, _, _) <- runRedisClient ["fill", "--host", "redis.local", "--data", "1", "--key-size", "256", "--value-size", "1024"] ""
        code `shouldBe` ExitSuccess
        -- With keySize=256, valueSize=1024, bytesPerCommand = 256 + 1024 = 1280 bytes
        -- 1GB = 1024 MB = 1,073,741,824 bytes
        -- Expected keys: ceiling(1,073,741,824 / 1280) = 838,861 keys
        dbSizeResp <- runRedisAction dbsize
        case dbSizeResp of
          RespInteger n -> do
            -- Allow ±0.1% tolerance due to remainder chunks
            let expected = 838861
            let lowerBound = round (fromIntegral expected * 0.999 :: Double)
            let upperBound = round (fromIntegral expected * 1.001 :: Double)
            n `shouldSatisfy` (\k -> k >= lowerBound && k <= upperBound)
          _ -> expectationFailure "Expected integer response from DBSIZE"

      it "cli mode responds to commands" $ do
        let cp =
              (proc redisClient ["cli", "--host", "redis.local"]) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
        withCreateProcess cp $ \(Just hin) (Just hout) (Just herr) ph -> do
          hSetBuffering hin LineBuffering
          hPutStrLn hin "PING"
          hPutStrLn hin "exit"
          hFlush hin
          hClose hin
          stdoutOut <- hGetContents hout
          stderrOut <- hGetContents herr
          exitCode <- waitForProcess ph
          void $ evaluate (length stdoutOut)
          void $ evaluate (length stderrOut)
          exitCode `shouldBe` ExitSuccess
          stdoutOut `shouldSatisfy` ("PONG" `isInfixOf`)

      it "tunnel proxies plaintext traffic to TLS redis" $ do
        let cp =
              (proc redisClient ["tunn", "--host", "redis.local", "--tls"])
                { std_out = CreatePipe,
                  std_err = CreatePipe,
                  env = Just (mergeEnv [])
                }
            viaTunnel :: RedisCommandClient PlainTextClient a -> IO a
            viaTunnel action =
              runCommandsAgainstPlaintextHost (RunState
                { host = "localhost"
                , port = Just 6379
                , username = "default"
                , password = ""
                , useTLS = False
                , dataGBs = 0
                , flush = False
                , serial = False
                , numConnections = Nothing
                , useCluster = False
                , tunnelMode = "smart"
                , keySize = 512
                }) action
        withCreateProcess cp $ \_ mOut mErr ph ->
          case (mOut, mErr) of
            (Just hout, Just herr) -> do
              hSetBuffering hout LineBuffering
              hSetBuffering herr LineBuffering
              let cleanup = cleanupProcess ph
              finally
                (do
                    ready <- timeout (5 * 1000000) (try (waitForSubstring hout "Listening on localhost:6379") :: IO (Either IOException ()))
                    case ready of
                      Nothing -> do
                        cleanup
                        stdoutRest <- drainHandle hout
                        stderrRest <- drainHandle herr
                        expectationFailure (unlines ["Tunnel did not report listening within timeout.", "stdout:", stdoutRest, "stderr:", stderrRest])
                      Just (Left err) -> do
                        cleanup
                        stdoutRest <- drainHandle hout
                        stderrRest <- drainHandle herr
                        expectationFailure (unlines ["Tunnel stdout closed unexpectedly: " <> show err, "stdout:", stdoutRest, "stderr:", stderrRest])
                      Just (Right ()) -> do
                        (pongResp, echoResp) <-
                          viaTunnel $ do
                            pong <- ping
                            _ <- set "tunnel:key" "via-tls"
                            val <- get "tunnel:key"
                            pure (pong, val)
                        pongResp `shouldBe` RespSimpleString "PONG"
                        echoResp `shouldBe` RespBulkString "via-tls"
                        runRedisAction (get "tunnel:key") `shouldReturn` RespBulkString "via-tls"
                        runRedisAction flushAll
                        postAccept <- timeout (2 * 1000000) (try (waitForSubstring hout "Accepted connection") :: IO (Either IOException ()))
                        case postAccept of
                          Nothing -> expectationFailure "Tunnel never logged an accepted connection"
                          Just (Left err) -> expectationFailure ("Reading tunnel output failed: " <> show err)
                          Just (Right ()) -> pure ()
                )
                cleanup
            _ -> do
              cleanupProcess ph
              expectationFailure "Tunnel process did not expose stdout/stderr handles"
