{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RedisCommandClient where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (..))
import Control.Exception (bracket)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.State as State
  ( MonadState (get, put),
    StateT,
    evalStateT,
  )
import Data.Attoparsec.ByteString.Char8 qualified as StrictParse
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as SB8
import Data.ByteString.Lazy.Char8 qualified as BSC
import Data.Kind (Type)
import Debug.Trace (trace, traceShow)
import Resp (Encodable (encode), RespData (..), parseRespData)

data ClientState client = ClientState
  { getClient :: client 'Connected,
    getParseBuffer :: SB8.ByteString
  }

data RedisCommandClient client (a :: Type) where
  RedisCommandClient :: (Client client) => {runRedisCommandClient :: State.StateT (ClientState client) IO a} -> RedisCommandClient client a

instance (Client client) => Functor (RedisCommandClient client) where
  fmap :: (a -> b) -> RedisCommandClient client a -> RedisCommandClient client b
  fmap f (RedisCommandClient s) = RedisCommandClient (fmap f s)

instance (Client client) => Applicative (RedisCommandClient client) where
  pure :: a -> RedisCommandClient client a
  pure = RedisCommandClient . pure
  (<*>) :: RedisCommandClient client (a -> b) -> RedisCommandClient client a -> RedisCommandClient client b
  RedisCommandClient f <*> RedisCommandClient s = RedisCommandClient (f <*> s)

instance (Client client) => Monad (RedisCommandClient client) where
  (>>=) :: RedisCommandClient client a -> (a -> RedisCommandClient client b) -> RedisCommandClient client b
  RedisCommandClient s >>= f = RedisCommandClient (s >>= \a -> let RedisCommandClient s' = f a in s')

instance (Client client) => MonadIO (RedisCommandClient client) where
  liftIO :: IO a -> RedisCommandClient client a
  liftIO = RedisCommandClient . liftIO

instance (Client client) => MonadState (ClientState client) (RedisCommandClient client) where
  get :: RedisCommandClient client (ClientState client)
  get = RedisCommandClient State.get
  put :: ClientState client -> RedisCommandClient client ()
  put = RedisCommandClient . State.put

instance (Client client) => MonadFail (RedisCommandClient client) where
  fail :: String -> RedisCommandClient client a
  fail = RedisCommandClient . liftIO . fail

class (MonadIO m) => RedisCommands m where
  auth :: String -> m RespData
  ping :: m RespData
  set :: String -> String -> m RespData
  get :: String -> m RespData
  mget :: [String] -> m RespData
  setnx :: String -> String -> m RespData
  decr :: String -> m RespData
  psetex :: String -> Int -> String -> m RespData
  bulkSet :: [(String, String)] -> m RespData
  flushAll :: m RespData
  dbsize :: m RespData
  del :: [String] -> m RespData
  exists :: [String] -> m RespData
  incr :: String -> m RespData
  hset :: String -> String -> String -> m RespData
  hget :: String -> String -> m RespData
  hmget :: String -> [String] -> m RespData
  hexists :: String -> String -> m RespData
  lpush :: String -> [String] -> m RespData
  lrange :: String -> Int -> Int -> m RespData
  expire :: String -> Int -> m RespData
  ttl :: String -> m RespData
  rpush :: String -> [String] -> m RespData
  lpop :: String -> m RespData
  rpop :: String -> m RespData
  sadd :: String -> [String] -> m RespData
  smembers :: String -> m RespData
  scard :: String -> m RespData
  sismember :: String -> String -> m RespData
  hdel :: String -> [String] -> m RespData
  hkeys :: String -> m RespData
  hvals :: String -> m RespData
  llen :: String -> m RespData
  lindex :: String -> Int -> m RespData
  clientSetInfo :: [String] -> m RespData
  zadd :: String -> [(Int, String)] -> m RespData
  zrange :: String -> Int -> Int -> Bool -> m RespData

wrapInRay :: [String] -> RespData
wrapInRay inp =
  let !res = RespArray . map (RespBulkString . BSC.pack) $ inp
   in res

instance (Client client) => RedisCommands (RedisCommandClient client) where
  ping :: RedisCommandClient client RespData
  ping = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["PING"])
    parseWith (receive client)

  set :: String -> String -> RedisCommandClient client RespData
  set k v = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SET", k, v])
    parseWith (receive client)

  get :: String -> RedisCommandClient client RespData
  get k = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["GET", k])
    parseWith (receive client)

  mget :: [String] -> RedisCommandClient client RespData
  mget keys = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("MGET" : keys))
    parseWith (receive client)

  setnx :: String -> String -> RedisCommandClient client RespData
  setnx key value = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SETNX", key, value])
    parseWith (receive client)

  decr :: String -> RedisCommandClient client RespData
  decr key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["DECR", key])
    parseWith (receive client)

  psetex :: String -> Int -> String -> RedisCommandClient client RespData
  psetex key milliseconds value = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["PSETEX", key, show milliseconds, value])
    parseWith (receive client)

  auth :: String -> RedisCommandClient client RespData
  auth password = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HELLO", "3", "AUTH", "default", password])
    parseWith (receive client)

  bulkSet :: [(String, String)] -> RedisCommandClient client RespData
  bulkSet kvs = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs))
    parseWith (receive client)

  flushAll :: RedisCommandClient client RespData
  flushAll = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["FLUSHALL"])
    parseWith (receive client)

  dbsize :: RedisCommandClient client RespData
  dbsize = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["DBSIZE"])
    parseWith (receive client)

  del :: [String] -> RedisCommandClient client RespData
  del keys = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("DEL" : keys))
    parseWith (receive client)

  exists :: [String] -> RedisCommandClient client RespData
  exists keys = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("EXISTS" : keys))
    parseWith (receive client)

  incr :: String -> RedisCommandClient client RespData
  incr key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["INCR", key])
    parseWith (receive client)

  hset :: String -> String -> String -> RedisCommandClient client RespData
  hset key field value = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HSET", key, field, value])
    parseWith (receive client)

  hget :: String -> String -> RedisCommandClient client RespData
  hget key field = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HGET", key, field])
    parseWith (receive client)

  hmget :: String -> [String] -> RedisCommandClient client RespData
  hmget key fields = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("HMGET" : key : fields))
    parseWith (receive client)

  hexists :: String -> String -> RedisCommandClient client RespData
  hexists key field = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HEXISTS", key, field])
    parseWith (receive client)

  lpush :: String -> [String] -> RedisCommandClient client RespData
  lpush key values = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("LPUSH" : key : values))
    parseWith (receive client)

  lrange :: String -> Int -> Int -> RedisCommandClient client RespData
  lrange key start stop = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LRANGE", key, show start, show stop])
    parseWith (receive client)

  expire :: String -> Int -> RedisCommandClient client RespData
  expire key seconds = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["EXPIRE", key, show seconds])
    parseWith (receive client)

  ttl :: String -> RedisCommandClient client RespData
  ttl key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["TTL", key])
    parseWith (receive client)

  rpush :: String -> [String] -> RedisCommandClient client RespData
  rpush key values = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("RPUSH" : key : values))
    parseWith (receive client)

  lpop :: String -> RedisCommandClient client RespData
  lpop key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LPOP", key])
    parseWith (receive client)

  rpop :: String -> RedisCommandClient client RespData
  rpop key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["RPOP", key])
    parseWith (receive client)

  sadd :: String -> [String] -> RedisCommandClient client RespData
  sadd key members = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("SADD" : key : members))
    parseWith (receive client)

  smembers :: String -> RedisCommandClient client RespData
  smembers key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SMEMBERS", key])
    parseWith (receive client)

  scard :: String -> RedisCommandClient client RespData
  scard key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SCARD", key])
    parseWith (receive client)

  sismember :: String -> String -> RedisCommandClient client RespData
  sismember key member = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SISMEMBER", key, member])
    parseWith (receive client)

  hdel :: String -> [String] -> RedisCommandClient client RespData
  hdel key fields = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("HDEL" : key : fields))
    parseWith (receive client)

  hkeys :: String -> RedisCommandClient client RespData
  hkeys key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HKEYS", key])
    parseWith (receive client)

  hvals :: String -> RedisCommandClient client RespData
  hvals key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HVALS", key])
    parseWith (receive client)

  llen :: String -> RedisCommandClient client RespData
  llen key = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LLEN", key])
    parseWith (receive client)

  lindex :: String -> Int -> RedisCommandClient client RespData
  lindex key index = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LINDEX", key, show index])
    parseWith (receive client)
  
  clientSetInfo :: [String] -> RedisCommandClient client RespData
  clientSetInfo info = do
    ClientState !client _ <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay (["CLIENT", "SETINFO"] ++ info))
    parseWith (receive client)

  zadd :: String -> [(Int, String)] -> RedisCommandClient client RespData
  zadd key members = do
    ClientState !client _ <- State.get
    let payload = concatMap (\(score, member) -> [show score, member]) members
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("ZADD" : key : payload))
    parseWith (receive client)

  zrange :: String -> Int -> Int -> Bool -> RedisCommandClient client RespData
  zrange key start stop withScores = do
    ClientState !client _ <- State.get
    let base = ["ZRANGE", key, show start, show stop]
        command = if withScores then base ++ ["WITHSCORES"] else base
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay command)
    parseWith (receive client)

data RunState = RunState
  { host :: String,
    port :: Maybe Int,
    password :: String,
    useTLS :: Bool,
    dataGBs :: Int,
    flush :: Bool
  }
  deriving (Show)

authenticate :: (Client client) => String -> RedisCommandClient client RespData
authenticate [] = return $ RespSimpleString "OK"
authenticate password = do 
  auth password
  clientSetInfo ["LIB-NAME", "seth-spaghetti"]
  clientSetInfo ["LIB-VER", "0.0.0"]

runCommandsAgainstTLSHost :: RunState -> RedisCommandClient TLSClient a -> IO a
runCommandsAgainstTLSHost st action = do
  bracket (connect (NotConnectedTLSClient (host st) (port st))) close $ \client -> do
    evalStateT (runRedisCommandClient (authenticate (password st) >> action)) (ClientState client SB8.empty)

runCommandsAgainstPlaintextHost :: RunState -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHost st action =
  bracket
    (connect $ NotConnectedPlainTextClient (host st) (port st))
    close
    $ \client -> evalStateT (runRedisCommandClient (authenticate (password st) >> action)) (ClientState client SB8.empty)

parseWith :: (Client client, Monad m, MonadState (ClientState client) m) => m SB8.ByteString -> m RespData
parseWith recv = head <$> parseManyWith 1 recv

parseManyWith :: (Client client, Monad m, MonadState (ClientState client) m) => Int -> m SB8.ByteString -> m [RespData]
parseManyWith cnt recv = do
  (ClientState !client !input) <- State.get
  case StrictParse.parse (StrictParse.count cnt parseRespData) input of
    StrictParse.Fail _ _ err -> error err
    part@(StrictParse.Partial f) -> runUntilDone client part recv
    StrictParse.Done remainder !r -> do
      State.put (ClientState client remainder)
      return r
  where
    runUntilDone :: (Client client, Monad m, MonadState (ClientState client) m) => client 'Connected -> StrictParse.IResult SB8.ByteString r -> m SB8.ByteString -> m r
    runUntilDone client (StrictParse.Fail _ _ err) _ = error err
    runUntilDone client (StrictParse.Partial f) getMore = getMore >>= (flip (runUntilDone client) getMore . f)
    runUntilDone client (StrictParse.Done remainder !r) _ = do
      State.put (ClientState client remainder)
      return r
