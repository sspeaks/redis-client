{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Redis (ByteString, ClusterClient, ClusterConfig (..),
              NodeAddress (..), PlainTextClient,
              PoolConfig (..), RespData (..),
              RedisCommands,
              Client (..), showBS, psetex,
              clusterPlaintextConnector, connectPlaintext,
              createClusterClient, closeClusterClient, runClusterCommandClient,
              Multiplexer, createMultiplexer, submitCommand, destroyMultiplexer,
              encodeCommandBuilder)
import qualified Redis

import Control.Exception (bracket, SomeException, finally, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Database.SQLite.Simple (FromRow (..), NamedParam (..), field, queryNamed)
import qualified Database.SQLite.Simple as SQLite
import Network.HTTP.Types (status200, status404, Header)
import Network.Wai (Application, Response, rawPathInfo, responseLBS)
import qualified Network.Wai.Handler.Warp as Warp
import System.Environment (lookupEnv)

-- | User type
data User = User
  { userId :: Int
  , userName :: Text
  , userEmail :: Text
  , userBio :: Maybe Text
  , userCreatedAt :: Text
  } deriving (Show)

instance FromRow User where
  fromRow = User <$> field <*> field <*> field <*> field <*> field

-- | Manual JSON encoder using ByteString Builder — no Aeson, no intermediate Value
-- Field order matches Aeson's alphabetical key sorting for byte-identical output
encodeUserBuilder :: User -> B.Builder
encodeUserBuilder u =
  B.char7 '{' <>
  jsonKey "bio" <> jsonMaybeText (userBio u) <> B.char7 ',' <>
  jsonKey "createdAt" <> jsonString (userCreatedAt u) <> B.char7 ',' <>
  jsonKey "email" <> jsonString (userEmail u) <> B.char7 ',' <>
  jsonKey "id" <> B.intDec (userId u) <> B.char7 ',' <>
  jsonKey "name" <> jsonString (userName u) <>
  B.char7 '}'

jsonKey :: BS.ByteString -> B.Builder
jsonKey k = B.char7 '"' <> B.byteString k <> B.char7 '"' <> B.char7 ':'

jsonString :: Text -> B.Builder
jsonString t = B.char7 '"' <> escapeJsonText t <> B.char7 '"'

jsonMaybeText :: Maybe Text -> B.Builder
jsonMaybeText Nothing = B.byteString "null"
jsonMaybeText (Just t) = jsonString t

-- | Escape JSON special characters. Uses bulk copy for safe spans.
escapeJsonText :: Text -> B.Builder
escapeJsonText = escapeBS . TE.encodeUtf8

-- | Emit safe byte spans in bulk, only switching to per-byte for escapes
escapeBS :: BS.ByteString -> B.Builder
escapeBS bs
  | BS.null bs = mempty
  | otherwise =
    let (safe, rest) = BS.break needsEscape bs
    in B.byteString safe <>
       case BS.uncons rest of
         Nothing -> mempty
         Just (w, rest') ->
           escapeWord8 w <> escapeBS rest'

needsEscape :: Word8 -> Bool
needsEscape w = w == 0x5C || w == 0x22 || w < 0x20
{-# INLINE needsEscape #-}

escapeWord8 :: Word8 -> B.Builder
escapeWord8 0x5C = B.byteString "\\\\"
escapeWord8 0x22 = B.byteString "\\\""
escapeWord8 0x0A = B.byteString "\\n"
escapeWord8 0x0D = B.byteString "\\r"
escapeWord8 0x09 = B.byteString "\\t"
escapeWord8 w    = B.word8 w

encodeUser :: User -> BS.ByteString
encodeUser = LBS.toStrict . B.toLazyByteString . encodeUserBuilder

-- | Abstract Redis operations
data RedisConn
  = StandaloneConn Multiplexer
  | ClusterConn (ClusterClient PlainTextClient)

cacheGet :: RedisConn -> ByteString -> IO RespData
cacheGet (StandaloneConn mux) key =
  submitCommand mux (encodeCommandBuilder ["GET", key])
cacheGet (ClusterConn client) key =
  runClusterCommandClient client (redisGet key)

cachePsetex :: RedisConn -> ByteString -> Int -> ByteString -> IO RespData
cachePsetex (StandaloneConn mux) key ms val =
  submitCommand mux (encodeCommandBuilder ["PSETEX", key, showBS ms, val])
cachePsetex (ClusterConn client) key ms val =
  runClusterCommandClient client (psetex key ms val)

redisGet :: (RedisCommands m) => ByteString -> m RespData
redisGet = Redis.get

cacheTTLMs :: Int
cacheTTLMs = 60000

parseUserId :: ByteString -> Maybe Int
parseUserId path =
  case BS.stripPrefix "/users/" path of
    Just rest -> case reads (BS8.unpack rest) of
      [(n, "")] -> Just n
      _         -> Nothing
    Nothing -> Nothing

app :: FilePath -> RedisConn -> Application
app sqliteDb redisConn req respond = do
  case parseUserId (rawPathInfo req) of
    Just uid -> handleGetUser sqliteDb redisConn uid respond
    Nothing  -> respond $ responseLBS status404 jsonContentType "{\"error\":\"Not found\"}"

jsonContentType :: [Header]
jsonContentType = [("Content-Type", "application/json")]

handleGetUser :: FilePath -> RedisConn -> Int -> (Network.Wai.Response -> IO b) -> IO b
handleGetUser sqliteDb redisConn uid respond = do
  let cacheKey = "user:" <> showBS uid
  cached <- (try $ cacheGet redisConn cacheKey :: IO (Either SomeException RespData))
  case cached of
    Right (RespBulkString val) ->
      respond $ responseLBS status200 jsonContentType (LBS.fromStrict val)
    _ -> do
      result <- withSqlite sqliteDb $ \conn ->
        queryNamed conn
          "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
          [":id" := uid]
      case (result :: [User]) of
        [] ->
          respond $ responseLBS status404 jsonContentType "{\"error\":\"User not found\"}"
        (user:_) -> do
          -- Use manual Builder encoder instead of Aeson
          let jsonBs = encodeUser user
          _ <- try $ cachePsetex redisConn cacheKey cacheTTLMs jsonBs :: IO (Either SomeException RespData)
          respond $ responseLBS status200 jsonContentType (LBS.fromStrict jsonBs)

withSqlite :: FilePath -> (SQLite.Connection -> IO a) -> IO a
withSqlite db action = SQLite.withConnection db $ \conn -> do
  SQLite.execute_ conn "PRAGMA busy_timeout=5000"
  action conn

main :: IO ()
main = do
  redisHost <- fromMaybe "localhost" <$> lookupEnv "REDIS_HOST"
  redisPort <- maybe 6379 read <$> lookupEnv "REDIS_PORT"
  redisCluster <- maybe False (== "true") <$> lookupEnv "REDIS_CLUSTER"
  sqliteDb <- fromMaybe "benchmarks/shared/bench.db" <$> lookupEnv "SQLITE_DB"
  appPort <- maybe 3000 read <$> lookupEnv "PORT"

  putStrLn $ "Haskell REST Benchmark (Manual JSON Builder, no Aeson)"
  putStrLn $ "  Redis: " ++ redisHost ++ ":" ++ show redisPort ++ (if redisCluster then " (cluster)" else " (standalone)")
  putStrLn $ "  SQLite: " ++ sqliteDb
  putStrLn $ "  Port: " ++ show appPort

  let settings = Warp.setPort appPort Warp.defaultSettings

  if redisCluster
    then do
      let config = ClusterConfig
            { clusterSeedNode = NodeAddress redisHost redisPort
            , clusterPoolConfig = PoolConfig
                { maxConnectionsPerNode = 10
                , connectionTimeout = 5
                , maxRetries = 3
                , useTLS = False
                }
            , clusterMaxRetries = 3
            , clusterRetryDelay = 100000
            , clusterTopologyRefreshInterval = 600
            , clusterUseMultiplexing = True
            }
      bracket
        (createClusterClient config clusterPlaintextConnector)
        closeClusterClient
        $ \client -> do
            putStrLn "Connected to Redis cluster"
            SQLite.withConnection sqliteDb $ \conn ->
              SQLite.execute_ conn "PRAGMA journal_mode=WAL"
            Warp.runSettings settings (app sqliteDb (ClusterConn client))
    else
      bracket
        (connectPlaintext redisHost redisPort)
        close
        $ \client -> do
            mux <- createMultiplexer client (receive client)
            putStrLn "Connected to Redis standalone (multiplexed)"
            SQLite.withConnection sqliteDb $ \conn ->
              SQLite.execute_ conn "PRAGMA journal_mode=WAL"
            Warp.runSettings settings (app sqliteDb (StandaloneConn mux)) `finally` destroyMultiplexer mux
