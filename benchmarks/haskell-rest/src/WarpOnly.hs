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
import Data.Aeson (ToJSON (..), object, (.=), encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Database.SQLite.Simple (FromRow (..), NamedParam (..), field, queryNamed)
import qualified Database.SQLite.Simple as SQLite
import Network.HTTP.Types (status200, status404, Header)
import Network.Wai (Application, Response, rawPathInfo, responseLBS)
import qualified Network.Wai.Handler.Warp as Warp
import System.Environment (lookupEnv)

-- | User type for JSON serialization
data User = User
  { userId :: Int
  , userName :: Text
  , userEmail :: Text
  , userBio :: Maybe Text
  , userCreatedAt :: Text
  } deriving (Show)

instance ToJSON User where
  toJSON u = object
    [ "id" .= userId u
    , "name" .= userName u
    , "email" .= userEmail u
    , "bio" .= userBio u
    , "createdAt" .= userCreatedAt u
    ]

instance FromRow User where
  fromRow = User <$> field <*> field <*> field <*> field <*> field

-- | Abstract Redis operations so we can use either standalone or cluster mode
data RedisConn
  = StandaloneConn Multiplexer
  | ClusterConn (ClusterClient PlainTextClient)

-- | Execute a GET command
cacheGet :: RedisConn -> ByteString -> IO RespData
cacheGet (StandaloneConn mux) key =
  submitCommand mux (encodeCommandBuilder ["GET", key])
cacheGet (ClusterConn client) key =
  runClusterCommandClient client (redisGet key)

-- | Execute a PSETEX command
cachePsetex :: RedisConn -> ByteString -> Int -> ByteString -> IO RespData
cachePsetex (StandaloneConn mux) key ms val =
  submitCommand mux (encodeCommandBuilder ["PSETEX", key, showBS ms, val])
cachePsetex (ClusterConn client) key ms val =
  runClusterCommandClient client (psetex key ms val)

-- | Wrappers for Redis commands
redisGet :: (RedisCommands m) => ByteString -> m RespData
redisGet = Redis.get

cacheTTLMs :: Int
cacheTTLMs = 60000

-- | Parse "/users/<id>" from raw path
parseUserId :: ByteString -> Maybe Int
parseUserId path =
  case BS.stripPrefix "/users/" path of
    Just rest -> case reads (BS8.unpack rest) of
      [(n, "")] -> Just n
      _         -> Nothing
    Nothing -> Nothing

-- | The Warp Application — handles GET /users/:id only
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
  -- Check Redis cache first
  cached <- (try $ cacheGet redisConn cacheKey :: IO (Either SomeException RespData))
  case cached of
    Right (RespBulkString val) ->
      respond $ responseLBS status200 jsonContentType (LBS.fromStrict val)
    _ -> do
      -- Fall back to SQLite
      result <- withSqlite sqliteDb $ \conn ->
        queryNamed conn
          "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
          [":id" := uid]
      case (result :: [User]) of
        [] ->
          respond $ responseLBS status404 jsonContentType "{\"error\":\"User not found\"}"
        (user:_) -> do
          let jsonBs = LBS.toStrict (encode user)
          -- Populate cache with TTL 60s
          _ <- try $ cachePsetex redisConn cacheKey cacheTTLMs jsonBs :: IO (Either SomeException RespData)
          respond $ responseLBS status200 jsonContentType (LBS.fromStrict jsonBs)

-- | Open a SQLite connection with busy_timeout set for concurrent access
withSqlite :: FilePath -> (SQLite.Connection -> IO a) -> IO a
withSqlite db action = SQLite.withConnection db $ \conn -> do
  SQLite.execute_ conn "PRAGMA busy_timeout=5000"
  action conn

main :: IO ()
main = do
  -- Read configuration from environment
  redisHost <- fromMaybe "localhost" <$> lookupEnv "REDIS_HOST"
  redisPort <- maybe 6379 read <$> lookupEnv "REDIS_PORT"
  redisCluster <- maybe False (== "true") <$> lookupEnv "REDIS_CLUSTER"
  sqliteDb <- fromMaybe "benchmarks/shared/bench.db" <$> lookupEnv "SQLITE_DB"
  appPort <- maybe 3000 read <$> lookupEnv "PORT"

  putStrLn $ "Haskell REST Benchmark (Warp-only, no Scotty)"
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
