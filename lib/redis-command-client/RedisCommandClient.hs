{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RedisCommandClient where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (..))
import Control.Monad.IO.Class
import Control.Monad.State as State
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy.Char8 qualified as BSC
import Data.Kind (Type)
import Data.Word (Word8)
import Resp (Encodable (encode), RespData (..), parseWith)

data RedisCommandClient client (a :: Type) where
  RedisCommandClient :: (Client client) => {runRedisCommandClient :: State.StateT (client 'Connected) IO a} -> RedisCommandClient client a

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

instance (Client client) => MonadState (client 'Connected) (RedisCommandClient client) where
  get :: RedisCommandClient client (client 'Connected)
  get = RedisCommandClient State.get
  put :: client 'Connected -> RedisCommandClient client ()
  put = RedisCommandClient . State.put

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

wrapInRay :: [String] -> RespData
wrapInRay inp =
  let !res = RespArray . map (RespBulkString . BSC.pack) $ inp
   in res

instance (Client client) => RedisCommands (RedisCommandClient client) where
  ping :: RedisCommandClient client RespData
  ping = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["PING"])
    liftIO $ parseWith (recieve client)

  set :: String -> String -> RedisCommandClient client RespData
  set k v = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SET", k, v])
    liftIO $ parseWith (recieve client)

  get :: String -> RedisCommandClient client RespData
  get k = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["GET", k])
    liftIO $ parseWith (recieve client)

  auth :: String -> RedisCommandClient client RespData
  auth password = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HELLO", "3", "AUTH", "default", password])
    liftIO $ parseWith (recieve client)

  bulkSet :: [(String, String)] -> RedisCommandClient client RespData
  bulkSet kvs = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs))
    liftIO $ parseWith (recieve client)

  flushAll :: RedisCommandClient client RespData
  flushAll = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["FLUSHALL"])
    liftIO $ parseWith (recieve client)

  dbsize :: RedisCommandClient client RespData
  dbsize = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["DBSIZE"])
    liftIO $ parseWith (recieve client)

  del :: [String] -> RedisCommandClient client RespData
  del keys = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("DEL" : keys))
    liftIO $ parseWith (recieve client)

  exists :: [String] -> RedisCommandClient client RespData
  exists keys = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("EXISTS" : keys))
    liftIO $ parseWith (recieve client)

  incr :: String -> RedisCommandClient client RespData
  incr key = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["INCR", key])
    liftIO $ parseWith (recieve client)

  hset :: String -> String -> String -> RedisCommandClient client RespData
  hset key field value = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HSET", key, field, value])
    liftIO $ parseWith (recieve client)

  hget :: String -> String -> RedisCommandClient client RespData
  hget key field = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["HGET", key, field])
    liftIO $ parseWith (recieve client)

  lpush :: String -> [String] -> RedisCommandClient client RespData
  lpush key values = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("LPUSH" : key : values))
    liftIO $ parseWith (recieve client)

  lrange :: String -> Int -> Int -> RedisCommandClient client RespData
  lrange key start stop = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LRANGE", key, show start, show stop])
    liftIO $ parseWith (recieve client)

  expire :: String -> Int -> RedisCommandClient client RespData
  expire key seconds = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["EXPIRE", key, show seconds])
    liftIO $ parseWith (recieve client)

  ttl :: String -> RedisCommandClient client RespData
  ttl key = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["TTL", key])
    liftIO $ parseWith (recieve client)

  rpush :: String -> [String] -> RedisCommandClient client RespData
  rpush key values = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("RPUSH" : key : values))
    liftIO $ parseWith (recieve client)

  lpop :: String -> RedisCommandClient client RespData
  lpop key = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["LPOP", key])
    liftIO $ parseWith (recieve client)

  rpop :: String -> RedisCommandClient client RespData
  rpop key = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["RPOP", key])
    liftIO $ parseWith (recieve client)

  sadd :: String -> [String] -> RedisCommandClient client RespData
  sadd key members = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ("SADD" : key : members))
    liftIO $ parseWith (recieve client)

  smembers :: String -> RedisCommandClient client RespData
  smembers key = do
    client <- State.get
    liftIO $ send client (Builder.toLazyByteString . encode $ wrapInRay ["SMEMBERS", key])
    liftIO $ parseWith (recieve client)

data RunState = RunState
  { host :: String,
    password :: String,
    useTLS :: Bool,
    dataGBs :: Int,
    flush :: Bool
  }
  deriving (Show)

authenticate :: (Client client) => String -> RedisCommandClient client RespData
authenticate [] = return $ RespSimpleString "OK"
authenticate password = auth password

runCommandsAgainstTLSHost :: RunState -> RedisCommandClient TLSClient a -> IO a
runCommandsAgainstTLSHost st action = do
  client <- connect (NotConnectedTLSClient (host st) Nothing)
  val <- evalStateT (runRedisCommandClient (authenticate (password st) >> action)) client
  close client
  return val

runCommandsAgainstPlaintextHost :: RunState -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHost st action = do
  let notConnectedClient = if host st == "localhost" then NotConnectedPlainTextClient "localhost" (Just (127, 0, 0, 1)) else NotConnectedPlainTextClient (host st) Nothing
  client <- connect notConnectedClient
  val <- evalStateT (runRedisCommandClient (authenticate (password st) >> action)) client
  close client
  return val