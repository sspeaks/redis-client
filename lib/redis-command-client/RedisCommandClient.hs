{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RedisCommandClient where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (..))
import Control.Monad.IO.Class
import Control.Monad.State as State
import Data.ByteString.Char8 qualified as BSC
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

class (MonadIO m) => RedisCommands m where
  auth :: String -> m RespData
  ping :: m RespData
  set :: String -> String -> m RespData
  get :: String -> m RespData
  bulkSet :: [(String, String)] -> m RespData

wrapInRay :: [String] -> RespData
wrapInRay = RespArray . map (RespBulkString . BSC.pack)

instance (Client client) => RedisCommands (RedisCommandClient client) where
  ping :: RedisCommandClient client RespData
  ping = RedisCommandClient $ do
    client <- State.get
    liftIO $ send client (encode $ wrapInRay ["PING"])
    liftIO $ parseWith (recieve client)

  set :: String -> String -> RedisCommandClient client RespData
  set k v = RedisCommandClient $ do
    client <- State.get
    liftIO $ send client (encode $ wrapInRay ["SET", k, v])
    liftIO $ parseWith (recieve client)

  get :: String -> RedisCommandClient client RespData
  get k = RedisCommandClient $ do
    client <- State.get
    liftIO $ send client (encode $ wrapInRay ["GET", k])
    liftIO $ parseWith (recieve client)

  auth :: String -> RedisCommandClient client RespData
  auth password = RedisCommandClient $ do
    client <- State.get
    liftIO $ send client (encode $ wrapInRay ["HELLO", "3", "AUTH", "default", password])
    liftIO $ parseWith (recieve client)

  bulkSet :: [(String, String)] -> RedisCommandClient client RespData
  bulkSet kvs = RedisCommandClient $ do
    client <- State.get
    liftIO $ send client (encode $ wrapInRay (["MSET"] <> concatMap (\(k, v) -> [k, v]) kvs))
    liftIO $ parseWith (recieve client)

runCommandsAgainstTLSHost :: String -> RedisCommandClient TLSClient a -> IO a
runCommandsAgainstTLSHost host action = do
  client <- connect (NotConnectedTLSClient host Nothing)
  val <- evalStateT (runRedisCommandClient action) client
  close client
  return val

runCommandsAgainstPlaintextHost :: String -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHost host action = do
  client <- connect (NotConnectedPlainTextClient host Nothing)
  val <- evalStateT (runRedisCommandClient action) client
  close client
  return val

runCommandsAgainstPlaintextHostWithTuple :: String -> (Word8, Word8, Word8, Word8) -> RedisCommandClient PlainTextClient a -> IO a
runCommandsAgainstPlaintextHostWithTuple host tup action = do
  client <- connect (NotConnectedPlainTextClient host (Just tup))
  val <- evalStateT (runRedisCommandClient action) client
  close client
  return val