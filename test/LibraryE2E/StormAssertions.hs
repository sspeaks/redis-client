module LibraryE2E.StormAssertions
  ( commandFailure
  , recordProgress
  , trySynchronous
  ) where

import           Control.Exception (SomeAsyncException, SomeException,
                                    fromException, throwIO, try)
import           Data.ByteString   (ByteString)
import           Data.IORef        (IORef, atomicModifyIORef')
import qualified Data.Map.Strict   as Map

commandFailure
  :: (Eq a, Show a)
  => Int
  -> String
  -> ByteString
  -> a
  -> Either SomeException a
  -> [String]
commandFailure tid operation key expected actual =
  case actual of
    Right result | result == expected -> []
    _ ->
      [stormDiagnostic tid operation key $
        "expected " ++ show expected ++ ", got " ++ show actual]

recordProgress
  :: IORef (Map.Map Int String)
  -> Int
  -> String
  -> ByteString
  -> IO ()
recordProgress progress tid operation key =
  atomicModifyIORef' progress $ \workers ->
    (Map.insert tid (stormDiagnostic tid operation key "in progress") workers, ())

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous action = do
  result <- try action
  case result of
    Left exception ->
      case fromException exception :: Maybe SomeAsyncException of
        Just async -> throwIO async
        Nothing    -> pure (Left exception)
    Right value -> pure (Right value)

stormDiagnostic :: Int -> String -> ByteString -> String -> String
stormDiagnostic tid operation key actual =
  "thread=" ++ show tid ++ ", operation=" ++ operation
    ++ ", key=" ++ show key ++ ", actual=" ++ actual
