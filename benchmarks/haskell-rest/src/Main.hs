{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Redis (ByteString, ClusterClient, ClusterConfig (..),
              NodeAddress (..), PlainTextClient,
              ConnectionStatus (..), PoolConfig (..), RespData (..),
              ClientState (..), RedisCommandClient (..), RedisCommands,
              Client (..), showBS, psetex, del,
              clusterPlaintextConnector, connectPlaintext,
              createClusterClient, closeClusterClient, runClusterCommandClient)
import qualified Redis

import Control.Exception (bracket, SomeException, try)
import qualified Control.Monad.State as State
import Data.Aeson (ToJSON (..), FromJSON (..), object, (.=), (.:), (.:?), withObject, encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import Database.SQLite.Simple (FromRow (..), NamedParam (..), changes, executeNamed, field, lastInsertRowId, queryNamed)
import qualified Database.SQLite.Simple as SQLite
import Network.HTTP.Types.Status (status201, status404)
import System.Environment (lookupEnv)
import Web.Scotty

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

-- | Request body for creating/updating users
data UserInput = UserInput
  { inputName :: Text
  , inputEmail :: Text
  , inputBio :: Maybe Text
  } deriving (Show)

instance FromJSON UserInput where
  parseJSON = withObject "UserInput" $ \v -> UserInput
    <$> v .: "name"
    <*> v .: "email"
    <*> v .:? "bio"

-- | Paginated response
data PaginatedResponse = PaginatedResponse
  { prPage :: Int
  , prLimit :: Int
  , prData :: [User]
  }

instance ToJSON PaginatedResponse where
  toJSON pr = object
    [ "page" .= prPage pr
    , "limit" .= prLimit pr
    , "data" .= prData pr
    ]

-- | Abstract Redis operations so we can use either standalone or cluster mode
data RedisConn
  = StandaloneConn (PlainTextClient 'Connected)
  | ClusterConn (ClusterClient PlainTextClient)

-- | Execute a Redis command that returns RespData
runRedis :: RedisConn -> (forall m. RedisCommands m => m RespData) -> IO RespData
runRedis (StandaloneConn client) action =
  State.evalStateT (runRedisCommandClient action) (ClientState client BS.empty)
runRedis (ClusterConn client) action =
  runClusterCommandClient client action

-- | Wrappers for Redis commands that clash with Scotty names
redisGet :: (RedisCommands m) => ByteString -> m RespData
redisGet = Redis.get

cacheTTLMs :: Int
cacheTTLMs = 60000

main :: IO ()
main = do
  -- Read configuration from environment
  redisHost <- fromMaybe "localhost" <$> lookupEnv "REDIS_HOST"
  redisPort <- maybe 6379 read <$> lookupEnv "REDIS_PORT"
  redisCluster <- maybe False (== "true") <$> lookupEnv "REDIS_CLUSTER"
  sqliteDb <- fromMaybe "benchmarks/shared/bench.db" <$> lookupEnv "SQLITE_DB"
  appPort <- maybe 3000 read <$> lookupEnv "PORT"

  putStrLn $ "Haskell REST Benchmark"
  putStrLn $ "  Redis: " ++ redisHost ++ ":" ++ show redisPort ++ (if redisCluster then " (cluster)" else " (standalone)")
  putStrLn $ "  SQLite: " ++ sqliteDb
  putStrLn $ "  Port: " ++ show appPort

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
            runApp appPort sqliteDb (ClusterConn client)
    else
      bracket
        (connectPlaintext redisHost redisPort)
        close
        $ \client -> do
            putStrLn "Connected to Redis standalone"
            runApp appPort sqliteDb (StandaloneConn client)

runApp :: Int -> FilePath -> RedisConn -> IO ()
runApp appPort sqliteDb redisConn = do
  scotty appPort $ do
    -- GET /users/:id - cache-aside
    get "/users/:id" $ do
      uid <- captureParam "id" :: ActionM Int
      let cacheKey = "user:" <> showBS uid

      -- Check Redis cache first
      cached <- liftIO $ (try $ runRedis redisConn (redisGet cacheKey) :: IO (Either SomeException RespData))
      case cached of
        Right (RespBulkString val) -> do
          setHeader "Content-Type" "application/json"
          raw (LBS.fromStrict val)
        _ -> do
          -- Fall back to SQLite
          result <- liftIO $ SQLite.withConnection sqliteDb $ \conn ->
            queryNamed conn
              "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
              [":id" := uid]
          case (result :: [User]) of
            [] -> do
              status status404
              json $ object ["error" .= ("User not found" :: Text)]
            (user:_) -> do
              let jsonBs = LBS.toStrict (encode user)
              -- Populate cache with TTL 60s
              _ <- liftIO $ try $ runRedis redisConn (psetex cacheKey cacheTTLMs jsonBs) :: ActionM (Either SomeException RespData)
              setHeader "Content-Type" "application/json"
              raw (LBS.fromStrict jsonBs)

    -- GET /users?page=&limit= - paginated list (not cached)
    get "/users" $ do
      mPage <- queryParamMaybe "page" :: ActionM (Maybe Int)
      mLimit <- queryParamMaybe "limit" :: ActionM (Maybe Int)
      let page = maybe 1 id mPage
          limit = maybe 20 id mLimit
      let l = min limit 100
          offset = (page - 1) * l
      users <- liftIO $ SQLite.withConnection sqliteDb $ \conn ->
        queryNamed conn
          "SELECT id, name, email, bio, created_at FROM users ORDER BY id LIMIT :limit OFFSET :offset"
          [":limit" := l, ":offset" := offset]
      json $ PaginatedResponse page l (users :: [User])

    -- POST /users
    post "/users" $ do
      input <- jsonData :: ActionM UserInput
      user <- liftIO $ SQLite.withConnection sqliteDb $ \conn -> do
        executeNamed conn
          "INSERT INTO users (name, email, bio) VALUES (:name, :email, :bio)"
          [ ":name" := inputName input
          , ":email" := inputEmail input
          , ":bio" := inputBio input
          ]
        rowId <- lastInsertRowId conn
        let uid = fromIntegral rowId :: Int
        rows <- queryNamed conn
          "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
          [":id" := uid] :: IO [User]
        case rows of
          (u:_) -> return u
          []    -> error "Failed to retrieve inserted user"

      -- Invalidate cache
      let cacheKey = "user:" <> showBS (userId user)
      _ <- liftIO $ try $ runRedis redisConn (del [cacheKey]) :: ActionM (Either SomeException RespData)

      status status201
      setHeader "Location" (TL.pack $ "/users/" ++ show (userId user))
      json user

    -- PUT /users/:id
    put "/users/:id" $ do
      uid <- captureParam "id" :: ActionM Int
      input <- jsonData :: ActionM UserInput

      result <- liftIO $ SQLite.withConnection sqliteDb $ \conn -> do
        -- Check exists
        existing <- queryNamed conn
          "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
          [":id" := uid] :: IO [User]
        case existing of
          [] -> return Nothing
          _  -> do
            executeNamed conn
              "UPDATE users SET name = :name, email = :email, bio = :bio WHERE id = :id"
              [ ":id" := uid
              , ":name" := inputName input
              , ":email" := inputEmail input
              , ":bio" := inputBio input
              ]
            rows <- queryNamed conn
              "SELECT id, name, email, bio, created_at FROM users WHERE id = :id"
              [":id" := uid] :: IO [User]
            case rows of
              (u:_) -> return (Just u)
              []    -> return Nothing

      case result of
        Nothing -> do
          status status404
          json $ object ["error" .= ("User not found" :: Text)]
        Just user -> do
          -- Invalidate cache
          let cacheKey = "user:" <> showBS uid
          _ <- liftIO $ try $ runRedis redisConn (del [cacheKey]) :: ActionM (Either SomeException RespData)
          json user

    -- DELETE /users/:id
    delete "/users/:id" $ do
      uid <- captureParam "id" :: ActionM Int

      rows <- liftIO $ SQLite.withConnection sqliteDb $ \conn -> do
        executeNamed conn "DELETE FROM users WHERE id = :id" [":id" := uid]
        changes conn

      if rows == 0
        then do
          status status404
          json $ object ["error" .= ("User not found" :: Text)]
        else do
          -- Remove from cache
          let cacheKey = "user:" <> showBS uid
          _ <- liftIO $ try $ runRedis redisConn (del [cacheKey]) :: ActionM (Either SomeException RespData)
          json $ object ["message" .= ("User deleted" :: Text)]
