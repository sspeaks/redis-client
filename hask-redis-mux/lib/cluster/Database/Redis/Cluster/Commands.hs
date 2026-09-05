{-# LANGUAGE OverloadedStrings #-}

-- | Generated Redis 7.2 command grammar and routing classification.
module Database.Redis.Cluster.Commands
  ( keylessCommands
  , requiresKeyCommands
  , CommandRouting (..)
  , classifyCommand
  ) where

import           Data.ByteString                           (ByteString)
import qualified Data.ByteString.Char8                     as BS8
import           Data.Char                                 (toUpper)
import qualified Data.List                                 as List
import qualified Data.Map.Strict                           as Map
import           Data.Maybe                                (mapMaybe)
import           Database.Redis.Cluster                    (calculateSlot)
import           Database.Redis.Cluster.Commands.Generated (generatedCommandSpecs)
import           Database.Redis.Cluster.Commands.Spec

-- | Result of classifying a command for cluster routing
data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | CommandError String
  deriving (Eq, Show)

data ParseResult = ParseResult
  { prRemaining :: [ByteString]
  , prKeys      :: [ByteString]
  , prCounts    :: Map.Map ByteString Int
  } deriving (Eq, Show)

classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  classifyCommandTokens (cmd : args)

classifyCommandTokens :: [ByteString] -> CommandRouting
classifyCommandTokens [] = CommandError "Empty command"
classifyCommandTokens rawTokens =
  case classifySpecial uppercaseTokens rawTokens of
    Just routing -> routing
    Nothing ->
      case parsedMatches of
        (keys, flags) : _ ->
          classifyKeys keys flags
        [] ->
          unknownCommandError
  where
    uppercaseTokens = map asciiUpper rawTokens
    samePrefix spec = prefixMatch uppercaseTokens (gcsTokens spec)
    prefixCandidates = filter samePrefix generatedCommandSpecs
    parsedMatches =
      mapMaybe (parseSpec rawTokens uppercaseTokens) prefixCandidates

    unknownCommandError =
      case rawTokens of
        cmd : rest ->
          let cmdUpper = asciiUpper cmd
              families =
                [ gcsTokens spec
                | spec <- generatedCommandSpecs
                , case gcsTokens spec of
                    token : _ -> token == cmdUpper
                    []        -> False
                ]
          in case (rest, families) of
              (sub : _, _ : _) | hasSubcommandFamilies cmdUpper families ->
                CommandError $ "Unknown subcommand for "
                  ++ BS8.unpack cmd ++ ": " ++ BS8.unpack sub
              _ -> CommandError $ "Unsupported command: " ++ BS8.unpack cmd
        [] -> CommandError "Empty command"

keylessCommands :: [ByteString]
keylessCommands =
  List.nub
    [ headToken
    | spec <- generatedCommandSpecs
    , null $ commandKeyTypes (gcsArguments spec)
    , headToken : _ <- [gcsTokens spec]
    ]

requiresKeyCommands :: [ByteString]
requiresKeyCommands =
  List.nub
    [ headToken
    | spec <- generatedCommandSpecs
    , not $ null $ commandKeyTypes (gcsArguments spec)
    , headToken : _ <- [gcsTokens spec]
    ]

hasSubcommandFamilies :: ByteString -> [[ByteString]] -> Bool
hasSubcommandFamilies cmd =
  any $ \tokens ->
    case tokens of
      first : _second : _ -> first == cmd
      _                   -> False

parseSpec
  :: [ByteString]
  -> [ByteString]
  -> GeneratedCommandSpec
  -> Maybe ([ByteString], [ByteString])
parseSpec original upper spec = do
  guardArity spec original
  let prefixLen = length (gcsTokens spec)
      originalTail = drop prefixLen original
      upperTail = drop prefixLen upper
  ParseResult rest keys _ <-
    selectBestParse $ parseArgs (gcsArguments spec) originalTail upperTail emptyParse
  if null rest
    then Just (keys, gcsFlags spec)
    else Nothing

selectBestParse :: [ParseResult] -> Maybe ParseResult
selectBestParse [] = Nothing
selectBestParse xs =
  Just $
    List.minimumBy
      (\left right -> compare (length $ prRemaining left) (length $ prRemaining right))
      xs

emptyParse :: ParseResult
emptyParse = ParseResult [] [] Map.empty

guardArity :: GeneratedCommandSpec -> [ByteString] -> Maybe ()
guardArity spec tokens
  | arity == 0 = Just ()
  | arity > 0 = if length tokens == arity then Just () else Nothing
  | otherwise = if length tokens >= abs arity then Just () else Nothing
  where
    arity = gcsArity spec

prefixMatch :: [ByteString] -> [ByteString] -> Bool
prefixMatch input expected
  | length input < length expected = False
  | otherwise = and $ zipWith (==) (take (length expected) input) expected

parseArgs
  :: [GeneratedArgument]
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseArgs [] original upper state =
  [state { prRemaining = original }]
parseArgs (arg:rest) original upper state = do
  next <- parseArgument arg original upper state
  parseArgs rest (prRemaining next) (dropConsumed upper original (prRemaining next)) next

parseArgument
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseArgument arg original upper state
  | gaMultiple arg =
      let parsed = parseMultiple arg original upper state
      in if gaOptional arg
          then parsed ++ [state { prRemaining = original }]
          else parsed
  | otherwise = parseSingle arg original upper state

parseMultiple
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseMultiple arg original upper state =
  case expectedRepeatCount arg state of
    Just n ->
      parseExactly n original upper state
    Nothing ->
      parseAtLeastOnce original upper state
  where
    singleton = arg { gaMultiple = False, gaOptional = False }

    parseExactly 0 xs _ st = [st { prRemaining = xs }]
    parseExactly n xs ups st = do
      next <- parseSingle singleton xs ups st
      let remOriginal = prRemaining next
          remUpper = dropConsumed ups xs remOriginal
      parseExactly (n - 1) remOriginal remUpper next

    parseAtLeastOnce xs ups st = do
      first <- parseSingle singleton xs ups st
      let remOriginal = prRemaining first
          remUpper = dropConsumed ups xs remOriginal
      first : continue remOriginal remUpper first

    continue xs ups st =
      case parseSingle singleton xs ups st of
        [] -> []
        nextStates -> do
          next <- nextStates
          let remOriginal = prRemaining next
              remUpper = dropConsumed ups xs remOriginal
          next : continue remOriginal remUpper next

expectedRepeatCount :: GeneratedArgument -> ParseResult -> Maybe Int
expectedRepeatCount arg state
  | gaName arg == "key" =
      Map.lookup "numkeys" (prCounts state)
        <|> Map.lookup "num-keys" (prCounts state)
  | gaName arg == "weight" =
      Map.lookup "numkeys" (prCounts state)
  | gaName arg == "ID" =
      Map.lookup "streams" (prCounts state)
  | otherwise = Nothing

parseSingle
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseSingle arg original upper state =
  case gaType arg of
    "pure-token" -> parseTokenThen arg original upper state
    "key"        -> parseScalar arg isNonEmpty original upper state
    "string"     -> parseScalar arg isNonEmpty original upper state
    "pattern"    -> parseScalar arg isNonEmpty original upper state
    "integer"    -> parseScalar arg isIntegerToken original upper state
    "unix-time"  -> parseScalar arg isIntegerToken original upper state
    "double"     -> parseScalar arg isDoubleToken original upper state
    "block"      -> parseBlock arg original upper state
    "oneof"      -> parseOneOf arg original upper state
    _            -> parseScalar arg isNonEmpty original upper state

parseTokenThen
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseTokenThen arg original upper state = do
  (_, remOriginal, remUpper) <- consumeToken (gaToken arg) original upper
  if null (gaChildren arg)
    then [state { prRemaining = remOriginal }]
    else parseArgs (gaChildren arg) remOriginal remUpper state

parseBlock
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseBlock arg original upper state = do
  (_, remOriginal, remUpper) <- consumeToken (gaToken arg) original upper
  parseArgs (gaChildren arg) remOriginal remUpper state

parseOneOf
  :: GeneratedArgument
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseOneOf arg original upper state = do
  (_, remOriginal, remUpper) <- consumeToken (gaToken arg) original upper
  option <- gaAlternatives arg
  parseArgs option remOriginal remUpper state

parseScalar
  :: GeneratedArgument
  -> (ByteString -> Bool)
  -> [ByteString]
  -> [ByteString]
  -> ParseResult
  -> [ParseResult]
parseScalar arg validator original upper state = do
  (_, remOriginal, remUpper) <- consumeToken (gaToken arg) original upper
  (value, remOriginal2, _remUpper2) <- consumeOne remOriginal remUpper
  if validator value
    then
      let stateWithValue =
            state
              { prRemaining = remOriginal2
              , prKeys =
                  if gaType arg == "key"
                    then prKeys state ++ [value]
                    else prKeys state
              , prCounts = recordCount arg value state
              }
      in [stateWithValue]
    else []

recordCount :: GeneratedArgument -> ByteString -> ParseResult -> Map.Map ByteString Int
recordCount arg value state
  | gaType arg == "integer" || gaType arg == "unix-time" =
      case parseInteger value of
        Just n ->
          Map.insert (gaName arg) n $
            if gaName arg == "numkeys"
              then Map.insert "num-keys" n (prCounts state)
              else prCounts state
        Nothing -> prCounts state
  | gaName arg == "streams" =
      let existing = Map.findWithDefault 0 "streams" (prCounts state)
      in Map.insert "streams" (existing + 1) (prCounts state)
  | otherwise = prCounts state

consumeToken
  :: Maybe ByteString
  -> [ByteString]
  -> [ByteString]
  -> [(Maybe ByteString, [ByteString], [ByteString])]
consumeToken Nothing original upper = [(Nothing, original, upper)]
consumeToken (Just token) original upper = do
  (candidate, remOriginal, remUpper) <- consumeOne original upper
  if candidate == token || asciiUpper candidate == asciiUpper token
    then [(Just token, remOriginal, remUpper)]
    else []

consumeOne :: [ByteString] -> [ByteString] -> [(ByteString, [ByteString], [ByteString])]
consumeOne (x:xs) (_:ups) = [(x, xs, ups)]
consumeOne _ _            = []

dropConsumed :: [ByteString] -> [ByteString] -> [ByteString] -> [ByteString]
dropConsumed uppers before after =
  drop (length before - length after) uppers

commandKeyTypes :: [GeneratedArgument] -> [ByteString]
commandKeyTypes args =
  [ gaType arg
  | arg <- flattenArguments args
  , gaType arg == "key"
  ]

flattenArguments :: [GeneratedArgument] -> [GeneratedArgument]
flattenArguments = concatMap flatten
  where
    flatten arg =
      arg
        : flattenArguments (gaChildren arg)
        ++ concatMap flattenArguments (gaAlternatives arg)

classifyKeys :: [ByteString] -> [ByteString] -> CommandRouting
classifyKeys [] _ = KeylessRoute
classifyKeys (k:rest) flags
  | isMovable = KeyedRoute k
  | allSameSlot (k : rest) = KeyedRoute k
  | otherwise =
      CommandError "CROSSSLOT Keys in request don't hash to the same slot"
  where
    isMovable = "MOVABLEKEYS" `elem` flags

allSameSlot :: [ByteString] -> Bool
allSameSlot [] = True
allSameSlot (k:ks) =
  let slot = calculateSlot k
  in all ((== slot) . calculateSlot) ks

asciiUpper :: ByteString -> ByteString
asciiUpper = BS8.map toUpper

isNonEmpty :: ByteString -> Bool
isNonEmpty = not . BS8.null

isIntegerToken :: ByteString -> Bool
isIntegerToken value =
  case parseInteger value of
    Just _  -> True
    Nothing -> False

parseInteger :: ByteString -> Maybe Int
parseInteger value =
  case BS8.readInt value of
    Just (n, rest)
      | BS8.null rest -> Just n
    _ -> Nothing

isDoubleToken :: ByteString -> Bool
isDoubleToken value =
  case reads (BS8.unpack value) :: [(Double, String)] of
    [(n, "")] -> n == n
    _         -> False

infixr 3 <|>
(<|>) :: Maybe a -> Maybe a -> Maybe a
(<|>) (Just x) _ = Just x
(<|>) Nothing y  = y

classifySpecial :: [ByteString] -> [ByteString] -> Maybe CommandRouting
classifySpecial upper original =
  case upper of
    "PING" : rest -> Just $
      if length rest <= 1 then KeylessRoute else CommandError "PING accepts at most one argument"
    "GET" : rest -> Just $ keyedExactOne "GET" rest original
    "SET" : rest -> Just $ classifySet rest original
    "MEMORY" : rest -> Just $ classifyMemory rest original
    "CLIENT" : rest -> Just $ classifyClient rest original
    "OBJECT" : rest -> Just $ classifyObject rest original
    "ZUNION" : rest -> Just $ classifySetOp True rest original
    "ZINTER" : rest -> Just $ classifySetOp True rest original
    "ZDIFF" : rest -> Just $ classifySetOp False rest original
    "XINFO" : rest -> Just $ classifyXInfo rest original
    "BLPOP" : rest -> Just $ classifyBlockingPop "BLPOP" rest original
    "BRPOP" : rest -> Just $ classifyBlockingPop "BRPOP" rest original
    "PFCOUNT" : rest -> Just $ classifyMultiKey "PFCOUNT" rest original
    "TOUCH" : rest -> Just $ classifyMultiKey "TOUCH" rest original
    "UNLINK" : rest -> Just $ classifyMultiKey "UNLINK" rest original
    "WATCH" : rest -> Just $ classifyMultiKey "WATCH" rest original
    "MSET" : rest -> Just $ classifyMset "MSET" rest original
    "MSETNX" : rest -> Just $ classifyMset "MSETNX" rest original
    "RENAME" : rest -> Just $ classifyRename rest original
    "COPY" : rest -> Just $ classifyCopy rest original
    "XREAD" : rest -> Just $ classifyXread rest original
    "XREADGROUP" : rest -> Just $ classifyXreadGroup rest original
    "EVAL" : rest -> Just $ classifyEvalLike "EVAL" rest original
    "FCALL" : rest -> Just $ classifyEvalLike "FCALL" rest original
    "GEOSEARCHSTORE" : rest -> Just $ classifyGeoSearchStore rest original
    _ -> Nothing

keyedExactOne :: String -> [ByteString] -> [ByteString] -> CommandRouting
keyedExactOne cmd rest original =
  case (rest, drop 1 original) of
    ([_], [key]) -> KeyedRoute key
    _            -> CommandError $ cmd ++ " requires exactly one key argument"

classifySet :: [ByteString] -> [ByteString] -> CommandRouting
classifySet upperRest original =
  case drop 1 original of
    key : _value : tailArgs
      | parseSetOptions (drop 2 upperRest) ->
          KeyedRoute key
      | otherwise ->
          CommandError "Malformed SET options"
    _ -> CommandError "SET requires key and value"
  where
    parseSetOptions [] = True
    parseSetOptions ("NX" : xs) = parseNoDup "NX" xs
    parseSetOptions ("XX" : xs) = parseNoDup "XX" xs
    parseSetOptions ("GET" : xs) = parseNoDup "GET" xs
    parseSetOptions ("EX" : v : xs) = isIntegerToken v && parseNoDup "EXPIRE" xs
    parseSetOptions ("PX" : v : xs) = isIntegerToken v && parseNoDup "EXPIRE" xs
    parseSetOptions ("EXAT" : v : xs) = isIntegerToken v && parseNoDup "EXPIRE" xs
    parseSetOptions ("PXAT" : v : xs) = isIntegerToken v && parseNoDup "EXPIRE" xs
    parseSetOptions ("KEEPTTL" : xs) = parseNoDup "EXPIRE" xs
    parseSetOptions _ = False

    parseNoDup token xs = token `notElem` xs && parseSetOptions xs

classifyMemory :: [ByteString] -> [ByteString] -> CommandRouting
classifyMemory upperRest original =
  case (upperRest, drop 1 original) of
    (["HELP"], _)         -> KeylessRoute
    (["STATS"], _)        -> KeylessRoute
    (["MALLOC-STATS"], _) -> KeylessRoute
    (["DOCTOR"], _)       -> KeylessRoute
    ("USAGE" : keyU : xs, _ : _ : key : _) ->
      case xs of
        [] -> KeyedRoute key
        ["SAMPLES", n] | isIntegerToken n -> KeyedRoute key
        _ -> CommandError "Malformed MEMORY USAGE arguments"
    (_ : _, _) -> CommandError $ "Unknown subcommand for MEMORY: " ++ unpackHead upperRest
    _          -> CommandError "MEMORY requires a subcommand"

classifyClient :: [ByteString] -> [ByteString] -> CommandRouting
classifyClient upperRest _ =
  case upperRest of
    [] -> CommandError "CLIENT requires a subcommand"
    sub : _
      | sub `elem`
          [ "HELP", "ID", "INFO", "LIST", "GETNAME", "PAUSE", "UNPAUSE"
          , "REPLY", "SETNAME", "KILL", "TRACKING", "TRACKINGINFO"
          , "UNBLOCK", "NO-EVICT", "NO-TOUCH", "CACHING"
          ] -> KeylessRoute
      | otherwise ->
          CommandError $ "Unknown subcommand for CLIENT: " ++ BS8.unpack sub

classifyObject :: [ByteString] -> [ByteString] -> CommandRouting
classifyObject upperRest original =
  case (upperRest, drop 1 original) of
    (["HELP"], _) -> KeylessRoute
    (sub : _, _ : key : [])
      | sub `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] ->
          KeyedRoute key
    (sub : _, _) | sub `elem` ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"] ->
        CommandError "OBJECT subcommand requires exactly one key"
    (sub : _, _) -> CommandError $ "Unknown subcommand for OBJECT: " ++ BS8.unpack sub
    _            -> CommandError "OBJECT requires a subcommand"

classifySetOp :: Bool -> [ByteString] -> [ByteString] -> CommandRouting
classifySetOp allowWeights upperRest original =
  case parseIntegerFromHead upperRest of
    Just (numKeys, restUpper)
      | numKeys <= 0 -> CommandError "numkeys must be positive"
      | otherwise ->
          let args = drop 2 original
          in if length args < numKeys
              then CommandError "Not enough keys for numkeys"
              else
                let keys = take numKeys args
                    remUpper = drop numKeys restUpper
                in if parseSetOpTail allowWeights numKeys remUpper
                    then classifyKeys keys []
                    else CommandError "Malformed set-operation options"
    Nothing -> CommandError "Missing or invalid numkeys"

parseSetOpTail :: Bool -> Int -> [ByteString] -> Bool
parseSetOpTail allowWeights numKeys tokens =
  go False False tokens
  where
    go _ _ [] = True
    go usedWeights usedAggregate ("WITHSCORES" : xs) = go usedWeights usedAggregate xs
    go False usedAggregate ("WEIGHTS" : xs)
      | allowWeights =
          let (weights, rest) = splitAt numKeys xs
          in length weights == numKeys && all isIntegerToken weights
            && go True usedAggregate rest
    go usedWeights False ("AGGREGATE" : mode : xs)
      | mode `elem` ["SUM", "MIN", "MAX"] = go usedWeights True xs
    go _ _ _ = False

classifyXInfo :: [ByteString] -> [ByteString] -> CommandRouting
classifyXInfo upperRest original =
  case (upperRest, drop 1 original) of
    (["HELP"], _) -> KeylessRoute
    ("STREAM" : _ : _, _ : key : _) -> KeyedRoute key
    (["GROUPS", _], _ : key : []) -> KeyedRoute key
    (["CONSUMERS", _, _], _ : key : _) -> KeyedRoute key
    (sub : _, _) -> CommandError $ "Unknown subcommand for XINFO: " ++ BS8.unpack sub
    _ -> CommandError "XINFO requires a subcommand"

classifyBlockingPop :: String -> [ByteString] -> [ByteString] -> CommandRouting
classifyBlockingPop cmd upperRest original =
  case drop 1 original of
    keysAndTimeout
      | length keysAndTimeout < 2 ->
          CommandError $ cmd ++ " requires at least one key and timeout"
      | otherwise ->
          let keys = init keysAndTimeout
              timeout = last keysAndTimeout
          in if isDoubleToken timeout
              then classifyKeys keys []
              else CommandError $ cmd ++ " timeout must be numeric"
  where
    _ = upperRest

classifyMultiKey :: String -> [ByteString] -> [ByteString] -> CommandRouting
classifyMultiKey cmd _upperRest original =
  case drop 1 original of
    []   -> CommandError $ cmd ++ " requires at least one key"
    keys -> classifyKeys keys []

classifyMset :: String -> [ByteString] -> [ByteString] -> CommandRouting
classifyMset cmd _upperRest original =
  case drop 1 original of
    args
      | length args < 2 || odd (length args) ->
          CommandError $ cmd ++ " requires key/value pairs"
      | otherwise ->
          classifyKeys (everyOther args) []
  where
    everyOther []       = []
    everyOther (k:_:xs) = k : everyOther xs
    everyOther _        = []

classifyRename :: [ByteString] -> [ByteString] -> CommandRouting
classifyRename _upperRest original =
  case drop 1 original of
    [source, dest] -> classifyKeys [source, dest] []
    _              -> CommandError "RENAME requires source and destination keys"

classifyCopy :: [ByteString] -> [ByteString] -> CommandRouting
classifyCopy upperRest original =
  case drop 1 original of
    source : dest : options
      | parseCopyOptions (drop 2 upperRest) -> classifyKeys [source, dest] []
      | otherwise                  -> CommandError "Malformed COPY options"
    _ -> CommandError "COPY requires source and destination keys"

parseCopyOptions :: [ByteString] -> Bool
parseCopyOptions []                 = True
parseCopyOptions ("DB" : n : rest)  = isIntegerToken n && parseCopyOptions rest
parseCopyOptions ("REPLACE" : rest) = parseCopyOptions rest
parseCopyOptions _                  = False

classifyXread :: [ByteString] -> [ByteString] -> CommandRouting
classifyXread upperRest original =
  case parseXreadPrelude upperRest of
    Just ("STREAMS" : payloadUpper) ->
      classifyStreamsAndIds payloadUpper (dropPayload original)
    _ -> CommandError "Malformed XREAD arguments"
  where
    dropPayload = drop (length upperRest + 1 - length (dropWhile (/= "STREAMS") upperRest))

classifyXreadGroup :: [ByteString] -> [ByteString] -> CommandRouting
classifyXreadGroup upperRest original =
  case upperRest of
    "GROUP" : _group : _consumer : _ ->
      case elemIndexBS "STREAMS" upperRest of
        Nothing -> CommandError "Malformed XREADGROUP arguments"
        Just ix ->
          let payload = drop (ix + 1) (drop 1 original)
          in classifyPairs payload
    _ -> CommandError "Malformed XREADGROUP arguments"
  where
    classifyPairs values
      | null values || odd (length values) =
          CommandError "STREAMS requires matching key/id pairs"
      | otherwise =
          let half = length values `div` 2
              keys = take half values
              ids = drop half values
          in if length keys == length ids
              then classifyKeys keys []
              else CommandError "STREAMS requires matching key/id pairs"

parseXreadPrelude :: [ByteString] -> Maybe [ByteString]
parseXreadPrelude ("COUNT" : n : rest)
  | isIntegerToken n = parseXreadPrelude rest
parseXreadPrelude ("BLOCK" : n : rest)
  | isIntegerToken n = parseXreadPrelude rest
parseXreadPrelude ("STREAMS" : rest) = Just ("STREAMS" : rest)
parseXreadPrelude _                  = Nothing

parseXreadGroupPrelude :: [ByteString] -> Maybe [ByteString]
parseXreadGroupPrelude ("COUNT" : n : rest)
  | isIntegerToken n = parseXreadGroupPrelude rest
parseXreadGroupPrelude ("BLOCK" : n : rest)
  | isIntegerToken n = parseXreadGroupPrelude rest
parseXreadGroupPrelude ("NOACK" : rest) = parseXreadGroupPrelude rest
parseXreadGroupPrelude ("STREAMS" : rest) = Just ("STREAMS" : rest)
parseXreadGroupPrelude _ = Nothing

classifyStreamsAndIds :: [ByteString] -> [ByteString] -> CommandRouting
classifyStreamsAndIds payloadUpper payloadOriginal =
  let values = drop 1 payloadOriginal
      half = length values `div` 2
  in if null values || odd (length values)
      then CommandError "STREAMS requires matching key/id pairs"
      else
        let keys = take half values
            ids = drop half values
        in if length keys == length ids
              && all (not . BS8.null) keys
              && all (not . BS8.null) ids
              && not (null payloadUpper)
            then classifyKeys keys []
            else CommandError "STREAMS requires matching key/id pairs"

classifyEvalLike :: String -> [ByteString] -> [ByteString] -> CommandRouting
classifyEvalLike cmd upperRest original =
  case upperRest of
    _script : numKeysToken : rest ->
      case parseInteger numKeysToken of
        Just numKeys
          | numKeys < 0 -> CommandError "numkeys must be non-negative"
          | otherwise ->
              let keys = take numKeys (drop 3 original)
              in if length keys == numKeys
                  then classifyKeys keys ["MOVABLEKEYS"]
                  else CommandError $ cmd ++ " key count does not match numkeys"
        _ -> CommandError "Invalid numkeys"
    _ -> CommandError $ cmd ++ " requires script/function and numkeys"

classifyGeoSearchStore :: [ByteString] -> [ByteString] -> CommandRouting
classifyGeoSearchStore upperRest original =
  case drop 1 original of
    dest : src : _ ->
      if parseGeoSearchTail (drop 2 upperRest)
        then classifyKeys [dest, src] ["MOVABLEKEYS"]
        else CommandError "Malformed GEOSEARCHSTORE options"
    _ -> CommandError "GEOSEARCHSTORE requires destination and source keys"

parseGeoSearchTail :: [ByteString] -> Bool
parseGeoSearchTail ("FROMMEMBER" : _ : rest)     = parseGeoBy rest
parseGeoSearchTail ("FROMLONLAT" : _ : _ : rest) = parseGeoBy rest
parseGeoSearchTail _                             = False

parseGeoBy :: [ByteString] -> Bool
parseGeoBy ("BYRADIUS" : radius : unit : rest)
  | isDoubleToken radius
  , unit `elem` ["M", "KM", "FT", "MI"] = parseGeoTail rest
parseGeoBy ("BYBOX" : width : height : unit : rest)
  | isDoubleToken width
  , isDoubleToken height
  , unit `elem` ["M", "KM", "FT", "MI"] = parseGeoTail rest
parseGeoBy _ = False

parseGeoTail :: [ByteString] -> Bool
parseGeoTail [] = True
parseGeoTail ("ASC" : rest) = parseGeoTail rest
parseGeoTail ("DESC" : rest) = parseGeoTail rest
parseGeoTail ("COUNT" : n : "ANY" : rest) = isIntegerToken n && parseGeoTail rest
parseGeoTail ("COUNT" : n : rest) = isIntegerToken n && parseGeoTail rest
parseGeoTail ("STOREDIST" : rest) = parseGeoTail rest
parseGeoTail _ = False

parseIntegerFromHead :: [ByteString] -> Maybe (Int, [ByteString])
parseIntegerFromHead (x:xs) = (, xs) <$> parseInteger x
parseIntegerFromHead []     = Nothing

elemIndexBS :: ByteString -> [ByteString] -> Maybe Int
elemIndexBS needle = go 0
  where
    go _ [] = Nothing
    go i (x:xs)
      | x == needle = Just i
      | otherwise   = go (i + 1) xs

unpackHead :: [ByteString] -> String
unpackHead (x:_) = BS8.unpack x
unpackHead []    = ""
