module CredentialConfig
  ( passwordEnvironmentVariable
  , passwordFileEnvironmentVariable
  , rejectCredentialArguments
  , resolveRedisPassword
  , resolveRedisPasswordFrom
  ) where

import           Control.Exception  (IOException, try)
import           Data.List          (isPrefixOf)
import           System.Environment (lookupEnv)

passwordEnvironmentVariable :: String
passwordEnvironmentVariable = "REDIS_CLIENT_PASSWORD"

passwordFileEnvironmentVariable :: String
passwordFileEnvironmentVariable = "REDIS_CLIENT_PASSWORD_FILE"

rejectCredentialArguments :: [String] -> Either String ()
rejectCredentialArguments args
  | any isCredentialArgument args =
      Left "Redis credentials cannot be passed as command-line arguments. Use REDIS_CLIENT_PASSWORD_FILE or REDIS_CLIENT_PASSWORD."
  | otherwise = Right ()
  where
    isCredentialArgument arg =
      arg == "-a"
        || arg == "--password"
        || "-a" `isPrefixOf` arg
        || "--password=" `isPrefixOf` arg

resolveRedisPassword :: IO String
resolveRedisPassword = do
  passwordFile <- lookupEnv passwordFileEnvironmentVariable
  environmentPassword <- lookupEnv passwordEnvironmentVariable
  resolveRedisPasswordFrom passwordFile environmentPassword readCredentialFile

resolveRedisPasswordFrom :: Maybe FilePath -> Maybe String -> (FilePath -> IO String) -> IO String
resolveRedisPasswordFrom (Just "") _ _ =
  ioError $ userError $ passwordFileEnvironmentVariable ++ " is set but empty."
resolveRedisPasswordFrom (Just path) _ readPassword = do
  result <- try (readPassword path) :: IO (Either IOException String)
  case result of
    Left _ ->
      ioError $ userError $ "Unable to read Redis credential file configured by " ++ passwordFileEnvironmentVariable ++ "."
    Right contents ->
      case stripSingleLineEnding contents of
        ""       -> ioError $ userError "Redis credential file is empty."
        password -> pure password
resolveRedisPasswordFrom Nothing environmentPassword _ =
  pure $ maybe "" id environmentPassword

readCredentialFile :: FilePath -> IO String
readCredentialFile = readFile

stripSingleLineEnding :: String -> String
stripSingleLineEnding value =
  case reverse value of
    '\n' : '\r' : rest -> reverse rest
    '\n' : rest        -> reverse rest
    _                  -> value
