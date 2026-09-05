{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands
  ( keylessCommands
  , requiresKeyCommands
  , CommandRouting (..)
  , classifyCommand
  , classifyRespCommand
  , supportedCommandCount
  ) where

import           Data.ByteString                           (ByteString)
import qualified Data.ByteString.Char8                     as BS8
import           Data.Char                                 (toUpper)
import           Data.List                                 (foldl')
import qualified Data.Map.Strict                           as Map
import           Database.Redis.Cluster                    (calculateSlot)
import           Database.Redis.Cluster.Commands.Generated
import           Database.Redis.Cluster.Commands.Types
import           Database.Redis.Resp                       (RespData (..))
import           Text.Read                                 (readMaybe)

data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | CommandError String
  deriving (Eq, Show)

classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args = classifyTokens (cmd : args)

classifyRespCommand :: RespData -> CommandRouting
classifyRespCommand (RespArray parts) =
  case traverse tokenFromResp parts of
    Left err     -> CommandError err
    Right tokens -> classifyTokens tokens
classifyRespCommand _ = CommandError "Expected RESP array command"

supportedCommandCount :: Int
supportedCommandCount = Map.size commandSpecMap

keylessCommands :: [ByteString]
keylessCommands =
  [ name
  | (name, defs) <- Map.toList commandSpecMap
  , all (null . generatedCommandKeySpecs) defs
  ]

requiresKeyCommands :: [ByteString]
requiresKeyCommands =
  [ name
  | (name, defs) <- Map.toList commandSpecMap
  , any (not . null . generatedCommandKeySpecs) defs
  ]

classifyTokens :: [ByteString] -> CommandRouting
classifyTokens [] = CommandError "Empty command"
classifyTokens tokens@(cmd : _) =
  let cmdUpper = uppercase cmd
      argc = length tokens
  in case Map.lookup cmdUpper commandSpecMap of
    Nothing ->
      CommandError $ "Unknown or unsupported Redis command: " ++ BS8.unpack cmd
    Just defs ->
      case validateCommand cmdUpper tokens of
        Just err -> CommandError err
        Nothing ->
          case selectByArity argc defs of
            [] ->
              CommandError $
                "Command " ++ BS8.unpack cmd
                  ++ " has invalid argument count"
            matchingDefs ->
              let keyedDefs =
                    filter (not . null . generatedCommandKeySpecs) matchingDefs
                  defsForExtraction =
                    if null keyedDefs then matchingDefs else keyedDefs
                  extracted =
                    tryExtractSpecialOrMetadata cmdUpper tokens defsForExtraction
              in case extracted of
                Left err   -> CommandError err
                Right keys -> finalizeRouting keys

tryExtractSpecialOrMetadata
  :: ByteString
  -> [ByteString]
  -> [GeneratedCommandSpec]
  -> Either String [ByteString]
tryExtractSpecialOrMetadata cmdUpper tokens defs =
  case extractSpecialKeys cmdUpper tokens of
    Just routed -> routed
    Nothing ->
      let attempts = map (extractKeysFromSpec tokens) defs
      in case [keys | Right keys <- attempts] of
           (keys : _) -> Right keys
           [] ->
             case [err | Left err <- attempts] of
               (err : _) ->
                 Left $ "Unable to derive routing keys: " ++ BS8.unpack err
               [] -> Right []

finalizeRouting :: [ByteString] -> CommandRouting
finalizeRouting [] = KeylessRoute
finalizeRouting (key : rest)
  | crossesSlots key rest =
      CommandError "CROSSSLOT Keys in request don't hash to the same slot"
  | otherwise = KeyedRoute key

crossesSlots :: ByteString -> [ByteString] -> Bool
crossesSlots firstKey =
  any ((/= calculateSlot firstKey) . calculateSlot)

commandSpecMap :: Map.Map ByteString [GeneratedCommandSpec]
commandSpecMap =
  Map.fromListWith (++) $
    map (\spec -> (generatedCommandName spec, [spec])) generatedCommandSpecs

selectByArity :: Int -> [GeneratedCommandSpec] -> [GeneratedCommandSpec]
selectByArity argc =
  filter (matchesArity argc . generatedCommandArity)

matchesArity :: Int -> Int -> Bool
matchesArity argc arity
  | arity >= 0 = argc == arity
  | otherwise  = argc >= abs arity

extractKeysFromSpec :: [ByteString] -> GeneratedCommandSpec -> Either ByteString [ByteString]
extractKeysFromSpec tokens spec = do
  keyGroups <- traverse (extractKeysFromKeySpec tokens) (generatedCommandKeySpecs spec)
  pure (concat keyGroups)

extractKeysFromKeySpec :: [ByteString] -> GeneratedKeySpec -> Either ByteString [ByteString]
extractKeysFromKeySpec tokens keySpec = do
  begin <- resolveBegin tokens (generatedBeginSearch keySpec)
  positions <- resolveFindKeys tokens begin (generatedFindKeys keySpec)
  pure
    [ tokens !! idx
    | idx <- positions
    , idx >= 0
    , idx < length tokens
    ]

resolveBegin :: [ByteString] -> BeginSearch -> Either ByteString Int
resolveBegin _ (BeginIndex idx) = Right idx
resolveBegin tokens (BeginKeyword keyword startFrom) =
  case findKeyword (uppercase keyword) startFrom tokens of
    Nothing  -> Right (-1)
    Just idx -> Right (idx + 1)
resolveBegin _ BeginSearchUnsupported =
  Left "unsupported begin_search in generated metadata"

resolveFindKeys :: [ByteString] -> Int -> FindKeys -> Either ByteString [Int]
resolveFindKeys _ begin _
  | begin < 0 = Right []
resolveFindKeys tokens begin (FindRange lastKey step limit)
  | step <= 0 = Left "invalid key-spec step <= 0"
  | otherwise =
      let argc = length tokens
          end
            | lastKey >= 0 = begin + lastKey
            | otherwise = argc + lastKey
      in if begin >= argc || end < begin || end >= argc
           then Right []
           else
             let raw = [begin, begin + step .. end]
             in if limit > 1
                  then
                    let keyCount = length raw `div` limit
                    in Right (take keyCount raw)
                  else Right raw
resolveFindKeys tokens begin (FindKeyNum keyNumIdx firstKey step)
  | step <= 0 = Left "invalid keynum step <= 0"
  | otherwise =
      let argc = length tokens
          keyNumPos = begin + keyNumIdx
          firstKeyPos = begin + firstKey
      in if keyNumPos < 0 || keyNumPos >= argc
           then Right []
           else do
             keyCount <- parseIntBS (tokens !! keyNumPos)
             if keyCount < 0
               then Left "negative key count is invalid"
               else
                 let positions = take keyCount [firstKeyPos, firstKeyPos + step ..]
                 in if any (\idx -> idx < 0 || idx >= argc) positions
                      then Left "declared key count exceeds argument list"
                      else Right positions
resolveFindKeys _ _ FindKeysUnsupported =
  Left "unsupported find_keys in generated metadata"

parseIntBS :: ByteString -> Either ByteString Int
parseIntBS token =
  case parseInt token of
    Left err -> Left (BS8.pack err)
    Right n  -> Right n

findKeyword :: ByteString -> Int -> [ByteString] -> Maybe Int
findKeyword needle startFrom tokens =
  let argc = length tokens
      start
        | startFrom >= 0 = startFrom
        | otherwise = argc + startFrom
      indexed = zip [0 ..] tokens
      matches = [idx | (idx, tok) <- indexed, idx >= max 0 start, uppercase tok == needle]
  in if null matches then Nothing else Just (last matches)

tokenFromResp :: RespData -> Either String ByteString
tokenFromResp (RespBulkString bs)   = Right bs
tokenFromResp (RespSimpleString bs) = Right bs
tokenFromResp (RespInteger n)       = Right (BS8.pack (show n))
tokenFromResp other =
  Left $ "Unsupported RESP argument type for routing: " ++ show other

extractSpecialKeys :: ByteString -> [ByteString] -> Maybe (Either String [ByteString])
extractSpecialKeys cmd tokens = case cmd of
  "SET" -> Just $ do
    validateSet tokens
    pure [tokens !! 1]
  "MEMORY" -> Just $ memoryKeys tokens
  "CLIENT" -> Just $ clientKeys tokens
  "OBJECT" -> Just $ objectKeys tokens
  "XINFO" -> Just $ xinfoKeys tokens
  "ZUNION" -> Just (zsetSetOpKeys tokens)
  "ZINTER" -> Just (zsetSetOpKeys tokens)
  "ZDIFF" -> Just (zsetSetOpKeys tokens)
  "BLPOP" -> Just (listBlockingKeys tokens)
  "BRPOP" -> Just (listBlockingKeys tokens)
  "MSET" -> Just (msetKeys tokens)
  "MSETNX" -> Just (msetKeys tokens)
  "RENAME" -> Just (binaryPairKeys tokens)
  "COPY" -> Just (copyKeys tokens)
  "XREAD" -> Just (xreadKeys tokens)
  "XREADGROUP" -> Just (xreadGroupKeys tokens)
  "EVAL" -> Just (scriptKeys tokens)
  "EVALSHA" -> Just (scriptKeys tokens)
  "FCALL" -> Just (scriptKeys tokens)
  "FCALL_RO" -> Just (scriptKeys tokens)
  "GEOSEARCHSTORE" -> Just (binaryPairKeys tokens)
  "GEORADIUS" -> Just (geoRadiusKeys 6 tokens)
  "GEORADIUSBYMEMBER" -> Just (geoRadiusKeys 5 tokens)
  _ -> Nothing

validateCommand :: ByteString -> [ByteString] -> Maybe String
validateCommand cmd tokens = either Just (const Nothing) $
  case extractSpecialKeys cmd tokens of
    Just parsed -> parsed >> pure ()
    Nothing     -> Right ()

validateSet :: [ByteString] -> Either String ()
validateSet tokens = go False False False False (drop 3 tokens)
  where
    go _ nx xx _ []
      | nx && xx = Left "SET options NX and XX are mutually exclusive"
      | otherwise = Right ()
    go expiry nx xx got (tok : rest)
      | opt == "NX" = go expiry True xx got rest
      | opt == "XX" = go expiry nx True got rest
      | opt == "GET" =
          if got
            then Left "SET option GET must not be repeated"
            else go expiry nx xx True rest
      | opt == "KEEPTTL" = go expiry nx xx got rest
      | opt `elem` ["EX", "PX", "EXAT", "PXAT"] =
          case rest of
            [] ->
              Left $ "SET option " ++ BS8.unpack tok ++ " requires an argument"
            _ : xs ->
              if expiry
                then Left "SET allows only one expiration option"
                else go True nx xx got xs
      | otherwise = Left $ "Unknown SET option: " ++ BS8.unpack tok
      where
        opt = uppercase tok

memoryKeys :: [ByteString] -> Either String [ByteString]
memoryKeys (_ : sub : rest)
  | s == "USAGE" =
      case rest of
        (key : []) -> Right [key]
        (key : samplesKeyword : _ : [])
          | uppercase samplesKeyword == "SAMPLES" -> Right [key]
        _ -> Left "MEMORY USAGE expects MEMORY USAGE key [SAMPLES count]"
  | s `elem` ["DOCTOR", "HELP", "MALLOC-STATS", "PURGE", "STATS"] =
      if null rest
        then Right []
        else Left $ "MEMORY " ++ BS8.unpack sub ++ " does not accept extra arguments"
  | otherwise = Left $ "Unknown MEMORY subcommand: " ++ BS8.unpack sub
  where
    s = uppercase sub
memoryKeys _ = Left "MEMORY requires a subcommand"

clientKeys :: [ByteString] -> Either String [ByteString]
clientKeys (_ : sub : rest)
  | s == "ID" =
      if null rest
        then Right []
        else Left "CLIENT ID does not accept extra arguments"
  | s `elem` clientKnownSubcommands = Right []
  | otherwise = Left $ "Unknown CLIENT subcommand: " ++ BS8.unpack sub
  where
    s = uppercase sub
clientKeys _ = Left "CLIENT requires a subcommand"

clientKnownSubcommands :: [ByteString]
clientKnownSubcommands =
  [ "CACHING", "GETNAME", "GETREDIR", "HELP", "INFO", "KILL", "LIST"
  , "NO-EVICT", "NO-TOUCH", "PAUSE", "REPLY", "SETINFO", "SETNAME"
  , "TRACKING", "TRACKINGINFO", "UNBLOCK", "UNPAUSE"
  ]

objectKeys :: [ByteString] -> Either String [ByteString]
objectKeys (_ : sub : key : [])
  | uppercase sub `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] = Right [key]
objectKeys (_ : sub : _)
  | uppercase sub `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] =
      Left $ "OBJECT " ++ BS8.unpack sub ++ " expects exactly one key"
objectKeys (_ : sub : _) =
  Left $ "Unknown OBJECT subcommand: " ++ BS8.unpack sub
objectKeys _ = Left "OBJECT requires a subcommand"

xinfoKeys :: [ByteString] -> Either String [ByteString]
xinfoKeys (_ : sub : rest)
  | s == "HELP" = if null rest then Right [] else Left "XINFO HELP takes no extra arguments"
  | s == "STREAM" =
      case rest of
        (key : _) -> Right [key]
        _         -> Left "XINFO STREAM expects a key"
  | s == "GROUPS" =
      case rest of
        [key] -> Right [key]
        _     -> Left "XINFO GROUPS expects exactly one key"
  | s == "CONSUMERS" =
      case rest of
        [key, _group] -> Right [key]
        _             -> Left "XINFO CONSUMERS expects key and group"
  | otherwise = Left $ "Unknown XINFO subcommand: " ++ BS8.unpack sub
  where
    s = uppercase sub
xinfoKeys _ = Left "XINFO requires a subcommand"

zsetSetOpKeys :: [ByteString] -> Either String [ByteString]
zsetSetOpKeys (_ : countToken : rest) = do
  keyCount <- parseInt countToken
  if keyCount <= 0
    then Left "Z*IFF/Z*INTER/Z*UNION require a positive key count"
    else do
      let (keys, options) = splitAt keyCount rest
      if length keys /= keyCount
        then Left "Declared key count does not match provided keys"
        else validateZsetOptions options >> Right keys
zsetSetOpKeys _ = Left "Z* set operations require numkeys and key list"

validateZsetOptions :: [ByteString] -> Either String ()
validateZsetOptions [] = Right ()
validateZsetOptions (tok : rest)
  | uppercase tok == "WITHSCORES" = validateZsetOptions rest
validateZsetOptions (tok : agg : rest)
  | uppercase tok == "AGGREGATE"
  , uppercase agg `elem` ["SUM", "MIN", "MAX"] = validateZsetOptions rest
validateZsetOptions (tok : rest)
  | uppercase tok == "WEIGHTS" = case consumeNumbers rest of
  (_, []) -> Left "WEIGHTS requires numeric values"
  ([], xs) -> Left $ "WEIGHTS requires numeric values, found " ++ show (map BS8.unpack xs)
  (_nums, xs) -> validateZsetOptions xs
validateZsetOptions (tok : _) =
  Left $ "Unknown or malformed sorted-set option: " ++ BS8.unpack tok

consumeNumbers :: [ByteString] -> ([Double], [ByteString])
consumeNumbers = go []
  where
    go acc [] = (reverse acc, [])
    go acc allTokens@(token : rest) =
      case parseDouble token of
        Just value -> go (value : acc) rest
        Nothing    -> (reverse acc, allTokens)

listBlockingKeys :: [ByteString] -> Either String [ByteString]
listBlockingKeys tokens
  | length tokens < 3 = Left "Blocking pop commands require at least one key and timeout"
  | otherwise =
      let keys = take (length tokens - 2) (drop 1 tokens)
          timeoutToken = last tokens
      in case parseDouble timeoutToken of
        Nothing -> Left "Blocking pop timeout must be numeric"
        Just _  ->
          if null keys
            then Left "Blocking pop commands require at least one key"
            else Right keys

msetKeys :: [ByteString] -> Either String [ByteString]
msetKeys (_ : rest)
  | null rest = Left "MSET/MSETNX require at least one key/value pair"
  | odd (length rest) =
      Left "MSET/MSETNX require key/value pairs"
  | otherwise = Right (everyOther rest)
  where
    everyOther []           = []
    everyOther (k : _ : xs) = k : everyOther xs
    everyOther _            = []
msetKeys _ = Left "MSET/MSETNX require key/value pairs"

binaryPairKeys :: [ByteString] -> Either String [ByteString]
binaryPairKeys (_ : k1 : k2 : _) = Right [k1, k2]
binaryPairKeys _                 = Left "Expected two key arguments"

copyKeys :: [ByteString] -> Either String [ByteString]
copyKeys (_ : source : destination : rest) = do
  validateCopyOptions rest
  Right [source, destination]
copyKeys _ = Left "COPY expects source and destination keys"

validateCopyOptions :: [ByteString] -> Either String ()
validateCopyOptions [] = Right ()
validateCopyOptions (tok : rest)
  | uppercase tok == "REPLACE" = validateCopyOptions rest
validateCopyOptions (tok : dbIndex : rest)
  | uppercase tok == "DB"
  , maybe False (>= 0) (either (const Nothing) Just (parseInt dbIndex)) =
      validateCopyOptions rest
validateCopyOptions (tok : _) =
  Left $ "Unknown or malformed COPY option: " ++ BS8.unpack tok

xreadKeys :: [ByteString] -> Either String [ByteString]
xreadKeys tokens = do
  streamsPos <- findStreamsPosition 1 tokens
  let beforeStreams = take streamsPos tokens
  validateXreadPrelude beforeStreams
  splitKeysAndIds streamsPos tokens

xreadGroupKeys :: [ByteString] -> Either String [ByteString]
xreadGroupKeys tokens@(_ : _ : _ : _ : rest) = do
  validateXreadGroupPrefix tokens
  streamsPos <- findStreamsPosition 4 tokens
  validateXreadGroupOptions (take streamsPos tokens)
  splitKeysAndIds streamsPos tokens
  where
    _ = rest
xreadGroupKeys _ =
  Left "XREADGROUP expects GROUP group consumer ... STREAMS key id"

validateXreadPrelude :: [ByteString] -> Either String ()
validateXreadPrelude (_ : opts) = go opts
  where
    go [] = Right ()
    go (opt : _ : xs)
      | uppercase opt == "COUNT" = go xs
      | uppercase opt == "BLOCK" = go xs
    go (opt : xs)
      | uppercase opt == "NOACK" = go xs
    go (tok : _) =
      Left $ "Unknown XREAD option before STREAMS: " ++ BS8.unpack tok
validateXreadPrelude _ = Left "XREAD requires arguments"

validateXreadGroupPrefix :: [ByteString] -> Either String ()
validateXreadGroupPrefix (_ : groupKeyword : _group : _consumer : _)
  | uppercase groupKeyword == "GROUP" = Right ()
validateXreadGroupPrefix (_ : sub : _)
  | uppercase sub /= "GROUP" =
      Left "XREADGROUP must start with GROUP group consumer"
validateXreadGroupPrefix _ =
  Left "XREADGROUP must start with GROUP group consumer"

validateXreadGroupOptions :: [ByteString] -> Either String ()
validateXreadGroupOptions (_ : _ : _ : _ : opts) = go opts
  where
    go [] = Right ()
    go (opt : _ : xs)
      | uppercase opt == "COUNT" = go xs
      | uppercase opt == "BLOCK" = go xs
    go (opt : xs)
      | uppercase opt == "NOACK" = go xs
    go (tok : _) =
      Left $ "Unknown XREADGROUP option before STREAMS: " ++ BS8.unpack tok
validateXreadGroupOptions _ = Left "Malformed XREADGROUP arguments"

findStreamsPosition :: Int -> [ByteString] -> Either String Int
findStreamsPosition start tokens =
  case [ idx
       | (idx, tok) <- zip [0 ..] tokens
       , idx >= start
       , uppercase tok == "STREAMS"
       ] of
    []      -> Left "XREAD/XREADGROUP requires STREAMS keyword"
    matches -> Right (last matches)

splitKeysAndIds :: Int -> [ByteString] -> Either String [ByteString]
splitKeysAndIds streamsPos tokens =
  let afterStreams = drop (streamsPos + 1) tokens
      countAfter = length afterStreams
  in if countAfter < 2 || odd countAfter
       then Left "STREAMS must be followed by equal numbers of keys and IDs"
       else Right (take (countAfter `div` 2) afterStreams)

scriptKeys :: [ByteString] -> Either String [ByteString]
scriptKeys tokens
  | length tokens < 3 = Left "Script command requires a key count"
  | otherwise = do
      keyCount <- parseInt (tokens !! 2)
      if keyCount < 0
        then Left "Script key count must be non-negative"
        else do
          let provided = drop 3 tokens
              keys = take keyCount provided
          if length keys /= keyCount
            then Left "Script key count exceeds provided keys"
            else Right keys

geoRadiusKeys :: Int -> [ByteString] -> Either String [ByteString]
geoRadiusKeys optionStart tokens
  | length tokens <= optionStart = Left "Malformed GEORADIUS command"
  | otherwise = do
      let source = tokens !! 1
      destination <- parseGeoStoreDestination (drop optionStart tokens)
      pure $ case destination of
        Nothing   -> [source]
        Just dest -> [source, dest]

parseGeoStoreDestination :: [ByteString] -> Either String (Maybe ByteString)
parseGeoStoreDestination = go Nothing
  where
    go current [] = Right current
    go _ (opt : dest : rest)
      | uppercase opt == "STORE" = go (Just dest) rest
      | uppercase opt == "STOREDIST" = go (Just dest) rest
    go current (_ : rest) = go current rest
    go _ [_] = Left "STORE/STOREDIST require a destination key"

parseInt :: ByteString -> Either String Int
parseInt token =
  case BS8.readInt token of
    Just (n, rest) | BS8.null rest -> Right n
    _ ->
      Left $ "Expected integer argument, got " ++ BS8.unpack token

parseDouble :: ByteString -> Maybe Double
parseDouble token =
  readMaybe (BS8.unpack token)

uppercase :: ByteString -> ByteString
uppercase = BS8.map toUpper
