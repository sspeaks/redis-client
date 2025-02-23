{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RedisCommandClient where

import Client (Client (..), ConnectionStatus (..), PlainTextClient (NotConnectedPlainTextClient), TLSClient (..))
import Control.Monad.IO.Class
import Control.Monad.State as State
import Data.ByteString.Lazy.Char8 qualified as BSC
import Data.Kind (Type)
import Data.Word (Word8)
import Resp (Encodable (encode), RespData (..), parseWith)
import qualified Data.ByteString.Builder as Builder

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

wrapInRay :: [String] -> RespData
wrapInRay = RespArray . map (RespBulkString . BSC.pack)

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