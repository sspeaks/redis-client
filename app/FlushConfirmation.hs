module FlushConfirmation
  ( canonicalFlushTarget
  , nonInteractiveConfirmation
  , interactiveConfirmation
  , confirmFlush
  ) where

import           Data.Maybe (fromMaybe)
import           System.IO  (hFlush, hIsTerminalDevice, isEOF, stdin, stdout)

canonicalFlushTarget :: String -> Maybe Int -> Bool -> Bool -> String
canonicalFlushTarget host port tls cluster =
  scheme ++ "://" ++ bracketIPv6 host ++ ":" ++ show effectivePort
    ++ "?tls=" ++ (if tls then "true" else "false") ++ "&scope=" ++ scope
  where
    scheme = if cluster then "redis+cluster" else "redis"
    effectivePort = fromMaybe (if tls then 6380 else 6379) port
    scope = if cluster then "all-primaries" else "single-node"

    bracketIPv6 value
      | ':' `elem` value && not ('[' `elem` value) = "[" ++ value ++ "]"
      | otherwise = value

nonInteractiveConfirmation :: Maybe String -> String -> Either String ()
nonInteractiveConfirmation acknowledgement target =
  case acknowledgement of
    Nothing ->
      Left $ "Refusing to flush " ++ target
        ++ ": non-interactive use requires --confirm-flush " ++ target
    Just value
      | value == target -> Right ()
      | otherwise ->
          Left $ "Refusing to flush " ++ target
            ++ ": --confirm-flush must exactly match the canonical target."

interactiveConfirmation :: Maybe String -> String -> Either String ()
interactiveConfirmation response target =
  case response of
    Just value | value == target -> Right ()
    _ -> Left $ "Flush cancelled: the target confirmation did not match " ++ target ++ "."

confirmFlush :: Maybe String -> String -> IO (Either String ())
confirmFlush acknowledgement target = do
  isTTY <- hIsTerminalDevice stdin
  if isTTY
    then do
      putStrLn $ "DANGER: --flush will issue FLUSHALL against " ++ target ++ "."
      putStr $ "Type the exact target to continue: "
      hFlush stdout
      eof <- isEOF
      response <- if eof then pure Nothing else Just <$> getLine
      pure $ interactiveConfirmation response target
    else pure $ nonInteractiveConfirmation acknowledgement target
