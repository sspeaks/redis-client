{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Monad.IO.Class        (liftIO)
import qualified Data.ByteString.Char8         as BS
import qualified Data.ByteString.Lazy.Char8    as LBS
import           Data.Maybe                    (fromMaybe)
import           Database.Redis
import           Database.Redis.Cluster.Client (withClusterClient)
import           Network.HTTP.Types.Status     (status404)
import           System.Environment            (getArgs)
import           System.IO                     (hFlush, hPutStrLn, stderr)
import           Text.Read                     (readMaybe)
import qualified Web.Scotty                    as S

-- | Parse CLI args: --port PORT --redis HOST:PORT
parseArgs :: [String] -> (Int, String, Int)
parseArgs = go 3000 "localhost" 7000
  where
    go p h r ("--port":v:rest)  = go (fromMaybe p (readMaybe v)) h r rest
    go p _ _ ("--redis":v:rest) =
      case break (== ':') v of
        (host, ':':portStr) -> go p host (fromMaybe 7000 (readMaybe portStr)) rest
        (host, _)           -> go p host 7000 rest
    go p h r (_:rest) = go p h r rest
    go p h r []       = (p, h, r)

-- | Mock data source: returns JSON for numeric IDs
mockDataSource :: String -> Maybe LBS.ByteString
mockDataSource idStr =
  case readMaybe idStr :: Maybe Int of
    Just n  -> Just $ LBS.pack $ "{\"id\":" ++ show n ++ ",\"name\":\"Item " ++ show n ++ "\"}"
    Nothing -> Nothing

main :: IO ()
main = do
  args <- getArgs
  let (port, redisHost, redisPort) = parseArgs args

  hPutStrLn stderr $ "Starting REST server on port " ++ show port
  hPutStrLn stderr $ "Redis cluster seed: " ++ redisHost ++ ":" ++ show redisPort
  hFlush stderr

  let config = ClusterConfig
        { clusterSeedNode                = NodeAddress redisHost redisPort
        , clusterPoolConfig              = PoolConfig
            { maxConnectionsPerNode = 4
            , connectionTimeout     = 5000000
            , maxRetries            = 3
            , useTLS                = False
            }
        , clusterMaxRetries              = 3
        , clusterRetryDelay              = 100000
        , clusterTopologyRefreshInterval = 600
        }

  withClusterClient config clusterPlaintextConnector $ \client -> do
    let run :: ClusterCommandClient PlainTextClient a -> IO a
        run = runClusterCommandClient client

    S.scotty port $ do
      S.get "/health" $ do
        S.text "OK"

      S.get "/item/:id" $ do
        itemId <- S.captureParam "id"
        let cacheKey = BS.pack $ "cache:item:" ++ itemId

        -- Cache-aside: check Redis first
        cached <- liftIO $ run (get cacheKey :: ClusterCommandClient PlainTextClient (Maybe BS.ByteString))
        case cached of
          Just val -> do
            S.setHeader "X-Cache" "HIT"
            S.setHeader "Content-Type" "application/json"
            S.raw (LBS.fromStrict val)
          Nothing -> do
            -- Cache miss: get from mock data source
            case mockDataSource itemId of
              Nothing -> do
                S.status status404
                S.text "Not found"
              Just jsonData -> do
                -- Populate cache with 60s TTL
                let val = LBS.toStrict jsonData
                _ <- liftIO $ run (psetex cacheKey 60000 val :: ClusterCommandClient PlainTextClient BS.ByteString)
                S.setHeader "X-Cache" "MISS"
                S.setHeader "Content-Type" "application/json"
                S.raw jsonData
