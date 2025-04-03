{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

module RedisCommandClient where

import           Client                           (Client (..),
                                                   ClusterClient (..),
                                                   ConnectionStatus (..),
                                                   PlainTextClient (NotConnectedPlainTextClient),
                                                   TLSClient (..))
import           Control.Exception                (bracket)
import           Control.Monad.IO.Class           (MonadIO (..))
import           Control.Monad.State              as State (MonadState (get, put),
                                                            StateT, evalStateT)
import qualified Data.Attoparsec.ByteString.Char8 as StrictParse
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as SB8
import qualified Data.ByteString.Lazy.Char8       as BSC
import           Data.Kind                        (Type)
import           Data.Word                        (Word8)
import           Debug.Trace                      (trace, traceShow)
import           Resp                             (Encodable (encode),
                                                   RespData (..), parseRespData)

data ClientState (client ::  Type) = ClientState
  { getClient      :: client,
    getParseBuffer :: SB8.ByteString
  }

data RedisCommandClient (client :: Type) (a :: Type) where
  RedisCommandClient :: (Client client) => {runRedisCommandClient :: State.StateT (ClientState (client  'Connected)) IO a} -> RedisCommandClient (client ' Connected) a

instance (Client client) => Functor (RedisCommandClient (client 'Connected)) where
  fmap :: (a -> b) -> RedisCommandClient (client 'Connected) a -> RedisCommandClient (client 'Connected) b
  fmap f (RedisCommandClient s) = RedisCommandClient (fmap f s)

instance (Client client) => Applicative (RedisCommandClient (client 'Connected)) where
  pure :: a -> RedisCommandClient (client 'Connected) a
  pure = RedisCommandClient . pure
  (<*>) :: RedisCommandClient (client 'Connected) (a -> b) -> RedisCommandClient (client 'Connected) a -> RedisCommandClient (client 'Connected) b
  RedisCommandClient f <*> RedisCommandClient s = RedisCommandClient (f <*> s)

instance (Client client) => Monad (RedisCommandClient (client 'Connected)) where
  (>>=) :: RedisCommandClient (client 'Connected) a -> (a -> RedisCommandClient (client 'Connected) b) -> RedisCommandClient (client 'Connected) b
  RedisCommandClient s >>= f = RedisCommandClient (s >>= \a -> let RedisCommandClient s' = f a in s')

instance (Client client) => MonadIO (RedisCommandClient (client 'Connected)) where
  liftIO :: IO a -> RedisCommandClient (client 'Connected) a
  liftIO = RedisCommandClient . liftIO

instance (Client client) => MonadState (ClientState (client 'Connected)) (RedisCommandClient (client 'Connected)) where
  get :: RedisCommandClient (client 'Connected) (ClientState (client 'Connected))
  get = RedisCommandClient State.get
  put :: ClientState (client 'Connected) -> RedisCommandClient (client 'Connected) ()
  put = RedisCommandClient . State.put

instance (Client client) => MonadFail (RedisCommandClient (client 'Connected)) where
  fail :: String -> RedisCommandClient (client 'Connected) a
  fail = RedisCommandClient . liftIO . fail

class (MonadIO m) => RedisCommands m where
  auth :: String -> m RespData
  ping :: m RespData
  set :: String -> String -> m RespData
  get :: String -> m RespData
  bulkSet :: [(String, String)] -> m RespData
  flushAll :: m RespData
  dbsize :: m RespData
  del :: [String] -> m RespData
  exists :: [String] -> m RespData
  incr :: String -> m RespData
  hset :: String -> String -> String -> m RespData
  hget :: String -> String -> m RespData
  lpush :: String -> [String] -> m RespData
  lrange :: String -> Int -> Int -> m RespData
  expire :: String -> Int -> m RespData
  ttl :: String -> m RespData
  rpush :: String -> [String] -> m RespData
  lpop :: String -> m RespData
  rpop :: String -> m RespData
  sadd :: String -> [String] -> m RespData
  smembers :: String -> m RespData
  hdel :: String -> [String] -> m RespData
  hkeys :: String -> m RespData
  hvals :: String -> m RespData
  llen :: String -> m RespData
  lindex :: String -> Int -> m RespData

wrapInRay :: [String] -> RespData
wrapInRay inp =
  let !res = RespArray . map (RespBulkString . BSC.pack) $ inp
   in res

instance (Client client) => RedisCommands (RedisCommandClient (client 'Connected)) where
  ping :: RedisCommandClient (client 'Connected) RespData
  ping = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ["PING"])
    parseWith (receive client mempty)

  set :: String -> String -> RedisCommandClient (client 'Connected) RespData
  set k v = do
    ClientState !client _ <- State.get
    liftIO $ send client k (Builder.toLazyByteString . encode $ wrapInRay ["SET", k, v])
    parseWith (receive client mempty)

  get :: String -> RedisCommandClient (client 'Connected) RespData
  get k = do
    ClientState !client _ <- State.get
    liftIO $ send client k (Builder.toLazyByteString . encode $ wrapInRay ["GET", k])
    parseWith (receive client mempty)

  auth :: String -> RedisCommandClient (client 'Connected) RespData
  auth password = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ["HELLO", "3", "AUTH", "default", password])
    parseWith (receive client mempty)

  bulkSet :: [(String, String)] -> RedisCommandClient (client 'Connected) RespData
  bulkSet kvs = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs))
    parseWith (receive client mempty)

  flushAll :: RedisCommandClient (client 'Connected) RespData
  flushAll = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ["FLUSHALL"])
    parseWith (receive client mempty)

  dbsize :: RedisCommandClient (client 'Connected) RespData
  dbsize = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ["DBSIZE"])
    parseWith (receive client mempty)

  del :: [String] -> RedisCommandClient (client 'Connected) RespData
  del keys = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ("DEL" : keys))
    parseWith (receive client mempty)

  exists :: [String] -> RedisCommandClient (client 'Connected) RespData
  exists keys = do
    ClientState !client _ <- State.get
    liftIO $ send client mempty (Builder.toLazyByteString . encode $ wrapInRay ("EXISTS" : keys))
    parseWith (receive client mempty)

  incr :: String -> RedisCommandClient (client 'Connected) RespData
  incr key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["INCR", key])
    parseWith (receive client key)

  hset :: String -> String -> String -> RedisCommandClient (client 'Connected) RespData
  hset key field value = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["HSET", key, field, value])
    parseWith (receive client key)

  hget :: String -> String -> RedisCommandClient (client 'Connected) RespData
  hget key field = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["HGET", key, field])
    parseWith (receive client key)

  lpush :: String -> [String] -> RedisCommandClient (client 'Connected) RespData
  lpush key values = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ("LPUSH" : key : values))
    parseWith (receive client key)

  lrange :: String -> Int -> Int -> RedisCommandClient (client 'Connected) RespData
  lrange key start stop = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["LRANGE", key, show start, show stop])
    parseWith (receive client key)

  expire :: String -> Int -> RedisCommandClient (client 'Connected) RespData
  expire key seconds = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["EXPIRE", key, show seconds])
    parseWith (receive client key)

  ttl :: String -> RedisCommandClient (client 'Connected) RespData
  ttl key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["TTL", key])
    parseWith (receive client key)

  rpush :: String -> [String] -> RedisCommandClient (client 'Connected) RespData
  rpush key values = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ("RPUSH" : key : values))
    parseWith (receive client key)

  lpop :: String -> RedisCommandClient (client 'Connected) RespData
  lpop key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["LPOP", key])
    parseWith (receive client key)

  rpop :: String -> RedisCommandClient (client 'Connected) RespData
  rpop key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["RPOP", key])
    parseWith (receive client key)

  sadd :: String -> [String] -> RedisCommandClient (client 'Connected) RespData
  sadd key members = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ("SADD" : key : members))
    parseWith (receive client key)

  smembers :: String -> RedisCommandClient (client 'Connected) RespData
  smembers key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["SMEMBERS", key])
    parseWith (receive client key)

  hdel :: String -> [String] -> RedisCommandClient (client 'Connected) RespData
  hdel key fields = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ("HDEL" : key : fields))
    parseWith (receive client key)

  hkeys :: String -> RedisCommandClient (client 'Connected) RespData
  hkeys key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["HKEYS", key])
    parseWith (receive client key)

  hvals :: String -> RedisCommandClient (client 'Connected) RespData
  hvals key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["HVALS", key])
    parseWith (receive client key)

  llen :: String -> RedisCommandClient (client 'Connected) RespData
  llen key = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["LLEN", key])
    parseWith (receive client key)

  lindex :: String -> Int -> RedisCommandClient (client 'Connected) RespData
  lindex key index = do
    ClientState !client _ <- State.get
    liftIO $ send client key (Builder.toLazyByteString . encode $ wrapInRay ["LINDEX", key, show index])
    parseWith (receive client key)

data RunState = RunState
  { host     :: String,
    port     :: Maybe Int,
    password :: String,
    useTLS   :: Bool,
    dataGBs  :: Int,
    flush    :: Bool
  }
  deriving (Show)

authenticate :: (Client client) => String -> RedisCommandClient (client 'Connected) RespData
authenticate []       = return $ RespSimpleString "OK"
authenticate password = auth password

runCommandsAgainstTLSHost :: RunState -> RedisCommandClient (TLSClient 'Connected) a -> IO a
runCommandsAgainstTLSHost st action = do
  bracket (connect (NotConnectedTLSClient (host st) Nothing)) close $ \client -> do
    evalStateT (runRedisCommandClient (authenticate (password st) >> action)) (ClientState client SB8.empty)

runCommandsAgainstPlaintextHost :: RunState -> RedisCommandClient (PlainTextClient 'Connected) a -> IO a
runCommandsAgainstPlaintextHost st action =
  bracket
    (connect $ NotConnectedPlainTextClient (host st) Nothing)
    close
    $ \client -> evalStateT (runRedisCommandClient (authenticate (password st) >> action)) (ClientState client SB8.empty)

parseWith :: (Client client, Monad m, MonadState (ClientState (client 'Connected)) m) => m SB8.ByteString -> m RespData
parseWith recv = head <$> parseManyWith 1 recv

parseManyWith :: (Client client, Monad m, MonadState (ClientState (client 'Connected)) m) => Int -> m SB8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  (ClientState !client !input) <- State.get
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> error err
    part@(StrictParse.Partial f) -> runUntilDone client part recv
    StrictParse.Done remainder !r -> do
      State.put (ClientState client remainder)
      return r
  where
    runUntilDone :: (Client client, Monad m, MonadState (ClientState (client 'Connected)) m) => client 'Connected -> StrictParse.IResult SB8.ByteString r -> m SB8.ByteString -> m r
    runUntilDone client (StrictParse.Fail _ _ err) _ = error err
    runUntilDone client (StrictParse.Partial f) getMore = getMore >>= (flip (runUntilDone client) getMore . f)
    runUntilDone client (StrictParse.Done remainder !r) _ = do
      State.put (ClientState client remainder)
      return r
