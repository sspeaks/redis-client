module Database.Redis.Client.TLSConfig
  ( tlsInsecureEnvironmentVariable
  , parseTLSVerificationBypass
  ) where

tlsInsecureEnvironmentVariable :: String
tlsInsecureEnvironmentVariable = "REDIS_CLIENT_TLS_INSECURE"

parseTLSVerificationBypass :: Maybe String -> Either String Bool
parseTLSVerificationBypass Nothing = Right False
parseTLSVerificationBypass (Just "") = Right False
parseTLSVerificationBypass (Just "0") = Right False
parseTLSVerificationBypass (Just "false") = Right False
parseTLSVerificationBypass (Just "1") = Right True
parseTLSVerificationBypass (Just value) =
  Left $
    tlsInsecureEnvironmentVariable
      ++ " must be exactly 1 to disable TLS certificate verification, or 0, false, or empty to keep verification enabled; received "
      ++ show value
      ++ "."
