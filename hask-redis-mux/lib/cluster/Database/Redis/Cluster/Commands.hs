{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands
  ( keylessCommands
  , requiresKeyCommands
  , CommandRouting (..)
  , classifyCommand
  ) where

import           Data.ByteString                           (ByteString)
import qualified Data.ByteString                           as BS
import qualified Data.ByteString.Char8                     as BS8
import           Data.Char                                 (toUpper)
import           Data.List                                 (find, isPrefixOf,
                                                            nubBy, sort)
import           Database.Redis.Cluster                    (calculateSlot)
import           Database.Redis.Cluster.Commands.Generated

data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | CommandError String
  deriving (Eq, Show)

data CommandSpec = CommandSpec
  { csTokens   :: [ByteString]
  , csArity    :: Int
  , csKeySpecs :: [KeySpec]
  }

specs :: [CommandSpec]
specs =
  [ CommandSpec (geTokens entry) (geArity entry) (geKeySpecs entry)
  | entry <- grammarEntries
  ]

keylessCommands :: [ByteString]
keylessCommands =
  sort
    . uniqueBytes
    $ [ token
      | spec <- specs
      , [token] <- [csTokens spec]
      , null (csKeySpecs spec)
      ]

requiresKeyCommands :: [ByteString]
requiresKeyCommands =
  sort
    . uniqueBytes
    $ [ token
      | spec <- specs
      , [token] <- [csTokens spec]
      , not (null (csKeySpecs spec))
      ]

classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  classifyTokens (cmd : args)

classifyTokens :: [ByteString] -> CommandRouting
classifyTokens [] = CommandError "Empty command"
classifyTokens rawTokens@(commandHead:_) =
  let normalized = map normalizeToken rawTokens
  in case matchCommandSpec normalized of
       Nothing ->
         CommandError $
           "Unknown or unsupported command: " ++ BS8.unpack commandHead
       Just spec -> doClassify spec rawTokens normalized

doClassify :: CommandSpec -> [ByteString] -> [ByteString] -> CommandRouting
doClassify spec rawTokens normalizedTokens =
  case validateArity spec rawTokens of
    Left err -> CommandError err
    Right () ->
      case validateSpecialForms (csTokens spec) (drop (length $ csTokens spec) normalizedTokens) of
        Left err -> CommandError err
        Right () ->
          case extractKeys spec rawTokens normalizedTokens of
            Left err -> CommandError err
            Right [] -> KeylessRoute
            Right (key:moreKeys) ->
              if sameSlot key moreKeys
                then KeyedRoute key
                else CommandError "CROSSSLOT Keys in request don't hash to the same slot"

validateArity :: CommandSpec -> [ByteString] -> Either String ()
validateArity spec rawTokens
  | csArity spec >= 0
  , length rawTokens /= csArity spec =
      Left $
        "Invalid arity for " ++ renderTokens (csTokens spec)
          ++ ": expected " ++ show (csArity spec)
          ++ ", got " ++ show (length rawTokens)
  | csArity spec < 0
  , length rawTokens < abs (csArity spec) =
      Left $
        "Invalid arity for " ++ renderTokens (csTokens spec)
          ++ ": expected at least " ++ show (abs (csArity spec))
          ++ ", got " ++ show (length rawTokens)
  | otherwise = Right ()

extractKeys :: CommandSpec -> [ByteString] -> [ByteString] -> Either String [ByteString]
extractKeys spec rawTokens normalizedTokens =
  fmap concat $
    mapM (extractKeysFromSpec rawTokens normalizedTokens) (csKeySpecs spec)

extractKeysFromSpec
  :: [ByteString]
  -> [ByteString]
  -> KeySpec
  -> Either String [ByteString]
extractKeysFromSpec rawTokens normalizedTokens keySpec = do
  begin <- resolveBeginSearch normalizedTokens (ksBeginSearch keySpec)
  case begin of
    Nothing -> Right []
    Just beginIndex -> do
      indexes <- resolveKeyIndexes normalizedTokens beginIndex (ksFindKeys keySpec)
      mapM (safeTokenAt rawTokens) indexes

resolveBeginSearch :: [ByteString] -> BeginSearch -> Either String (Maybe Int)
resolveBeginSearch _ (BeginSearchIndex pos) = Right (Just pos)
resolveBeginSearch normalizedTokens (BeginSearchKeyword keyword startFrom) =
  case findIndexFrom startFrom (== normalizeToken keyword) normalizedTokens of
    Nothing    -> Right Nothing
    Just index -> Right (Just (index + 1))
resolveBeginSearch _ BeginSearchUnknown =
  Left "Unsupported begin-search key grammar"

resolveKeyIndexes :: [ByteString] -> Int -> FindKeys -> Either String [Int]
resolveKeyIndexes normalizedTokens startIndex findKeys =
  let total = length normalizedTokens
  in case findKeys of
       FindKeysRange lastKey step limit ->
         rangeIndexes total startIndex lastKey step limit
       FindKeysKeyNum keyNumIdx firstKey step -> do
         numKeysPos <- addPositive startIndex keyNumIdx
         rawCount <- safeTokenAt normalizedTokens numKeysPos
         keyCount <- parseNonNegativeInteger "numkeys/count" rawCount
         firstKeyIndex <- addPositive startIndex firstKey
         pure [firstKeyIndex + (offset * step) | offset <- [0 .. keyCount - 1]]
       FindKeysUnknown ->
         case normalizedTokens of
           commandHead:_
             | commandHead `elem` ["SORT", "SORT_RO"] -> pure [startIndex]
           _ -> Left "Unsupported find-keys key grammar"

rangeIndexes :: Int -> Int -> Int -> Int -> Int -> Either String [Int]
rangeIndexes total startIndex lastKey step limit
  | step <= 0 = Left "Invalid key-spec step: must be positive"
  | startIndex < 0 || startIndex >= total = Left "Key begin-search index outside command bounds"
  | otherwise =
      let finalIndex
            | limit > 0 =
                let keyCount = (total - startIndex) `div` limit
                in startIndex + keyCount - 1
            | lastKey >= 0 = startIndex + lastKey
            | otherwise = total + lastKey
      in if finalIndex < startIndex
           then Right []
           else Right [startIndex, startIndex + step .. finalIndex]

validateSpecialForms :: [ByteString] -> [ByteString] -> Either String ()
validateSpecialForms tokens args
  | tokens == ["SET"] = validateSet args
  | tokens `elem` [["ZUNION"], ["ZINTER"], ["ZDIFF"]] = validateZSetSetOps tokens args
  | tokens == ["MSET"] = validateMSet args
  | tokens `elem` [["EVAL"], ["EVALSHA"], ["FCALL"], ["FCALL_RO"]] = validateNumKeys args
  | tokens == ["XREAD"] = validateXRead False args
  | tokens == ["XREADGROUP"] = validateXRead True args
  | tokens == ["XINFO"] = validateXInfo args
  | tokens == ["GEORADIUS"] = validateGeoRadiusMutable 5 args
  | tokens == ["GEORADIUSBYMEMBER"] = validateGeoRadiusMutable 4 args
  | tokens == ["GEOSEARCH"] = validateGeoSearch args
  | tokens == ["COPY"] = validateCopy args
  | otherwise = Right ()

validateSet :: [ByteString] -> Either String ()
validateSet args
  | length args < 2 = Left "SET requires key and value"
  | otherwise = go (drop 2 args) Nothing False Nothing
  where
    go [] condSeen _ _
      | condSeen == Just "BOTH" = Left "SET options NX and XX are mutually exclusive"
      | otherwise = Right ()
    go (opt:rest) condSeen getSeen expirySeen
      | opt `elem` ["NX", "XX"] =
          let condSeen'
                | condSeen == Nothing = Just opt
                | condSeen == Just opt = condSeen
                | otherwise = Just "BOTH"
          in go rest condSeen' getSeen expirySeen
      | opt == "GET" =
          if getSeen
            then Left "SET option GET cannot be repeated"
            else go rest condSeen True expirySeen
      | opt `elem` ["EX", "PX", "EXAT", "PXAT"] =
          case rest of
            [] -> Left $ "SET option " ++ BS8.unpack opt ++ " requires an argument"
            value:tailArgs ->
              case parseNonNegativeInteger (BS8.unpack opt) value of
                Left err -> Left err
                Right _ ->
                  case expirySeen of
                    Nothing -> go tailArgs condSeen getSeen (Just opt)
                    Just _  -> Left "SET expiration options are mutually exclusive"
      | opt == "KEEPTTL" =
          case expirySeen of
            Nothing -> go rest condSeen getSeen (Just opt)
            Just _  -> Left "SET expiration options are mutually exclusive"
      | otherwise = Left $ "SET has invalid option: " ++ BS8.unpack opt

validateMSet :: [ByteString] -> Either String ()
validateMSet args
  | null args = Left "MSET requires at least one key/value pair"
  | odd (length args) = Left "MSET requires key/value pairs"
  | otherwise = Right ()

validateNumKeys :: [ByteString] -> Either String ()
validateNumKeys args =
  case args of
    _scriptOrFunction:numKeysToken:rest -> do
      numKeys <- parseNonNegativeInteger "numkeys" numKeysToken
      if length rest < numKeys
        then Left "numkeys exceeds available key arguments"
        else Right ()
    _ -> Left "Command requires script/function and numkeys"

validateZSetSetOps :: [ByteString] -> [ByteString] -> Either String ()
validateZSetSetOps tokens args =
  case args of
    numKeysToken:rest -> do
      numKeys <- parsePositiveInteger "numkeys" numKeysToken
      if length rest < numKeys
        then Left "numkeys exceeds available key arguments"
        else parseTail numKeys (drop numKeys rest)
    [] -> Left $ renderTokens tokens ++ " requires numkeys"
  where
    parseTail _ [] = Right ()
    parseTail numKeys ("WEIGHTS":tailArgs)
      | length tailArgs < numKeys =
          Left "WEIGHTS requires one weight per key"
      | otherwise = parseTail numKeys (drop numKeys tailArgs)
    parseTail numKeys ("AGGREGATE":kind:tailArgs)
      | tokens == ["ZDIFF"] = Left "ZDIFF does not support AGGREGATE"
      | kind `elem` ["SUM", "MIN", "MAX"] = parseTail numKeys tailArgs
      | otherwise = Left "AGGREGATE must be SUM, MIN, or MAX"
    parseTail numKeys ("WITHSCORES":tailArgs) = parseTail numKeys tailArgs
    parseTail _ (token:_) = Left $ "Unexpected option for set-op command: " ++ BS8.unpack token

validateXRead :: Bool -> [ByteString] -> Either String ()
validateXRead isGroup args = do
  remaining <- if isGroup then parseGroupPrefix args else Right args
  parseOptions remaining
  where
    parseGroupPrefix ("GROUP":groupName:consumerName:tailArgs)
      | BS.null groupName || BS.null consumerName = Left "GROUP requires non-empty group and consumer"
      | otherwise = Right tailArgs
    parseGroupPrefix _ = Left "XREADGROUP requires GROUP <group> <consumer> prefix"

    parseOptions tokens = do
      (beforeStreams, afterStreams) <- breakAtKeyword "STREAMS" tokens
      parseXReadOptions beforeStreams
      case afterStreams of
        []                  -> Left "XREAD/XREADGROUP requires STREAMS section"
        _keyword:streamTail -> parseStreamsTail streamTail

    parseStreamsTail streamArgs
      | null streamArgs = Left "STREAMS requires at least one key and id"
      | odd (length streamArgs) = Left "STREAMS requires matching key and id counts"
      | otherwise = Right ()

validateXInfo :: [ByteString] -> Either String ()
validateXInfo args =
  case args of
    [] -> Left "XINFO requires subcommand"
    sub:rest
      | sub == "HELP" ->
          if null rest then Right () else Left "XINFO HELP does not take extra arguments"
      | sub `elem` ["STREAM", "GROUPS"] ->
          case rest of
            []      -> Left $ BS8.unpack sub ++ " requires a stream key"
            _key:xs ->
              if sub == "STREAM" then validateXInfoStreamTail xs else validateNoExtra xs
      | sub == "CONSUMERS" ->
          case rest of
            _key:_group:xs -> validateNoExtra xs
            _              -> Left "XINFO CONSUMERS requires stream and group"
      | otherwise -> Left $ "Unknown XINFO subcommand: " ++ BS8.unpack sub
  where
    validateNoExtra [] = Right ()
    validateNoExtra _  = Left "Unexpected extra arguments"

    validateXInfoStreamTail [] = Right ()
    validateXInfoStreamTail ["FULL"] = Right ()
    validateXInfoStreamTail ["FULL", "COUNT", n] = parseNonNegativeInteger "COUNT" n >> Right ()
    validateXInfoStreamTail _ = Left "Malformed XINFO STREAM options"

validateGeoRadiusMutable :: Int -> [ByteString] -> Either String ()
validateGeoRadiusMutable requiredPrefix args
  | length args < requiredPrefix = Left "GEORADIUS form is missing required arguments"
  | otherwise = validateGeoRadiusFlags (drop requiredPrefix args)

validateGeoRadiusFlags :: [ByteString] -> Either String ()
validateGeoRadiusFlags [] = Right ()
validateGeoRadiusFlags ("WITHCOORD":rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("WITHDIST":rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("WITHHASH":rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("ASC":rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("DESC":rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("COUNT":n:rest) = do
  _ <- parsePositiveInteger "COUNT" n
  case rest of
    "ANY":tailArgs -> validateGeoRadiusFlags tailArgs
    _              -> validateGeoRadiusFlags rest
validateGeoRadiusFlags ("STORE":_key:rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags ("STOREDIST":_key:rest) = validateGeoRadiusFlags rest
validateGeoRadiusFlags (token:_) =
  Left $ "Malformed GEO* radius option: " ++ BS8.unpack token

validateGeoSearch :: [ByteString] -> Either String ()
validateGeoSearch args =
  case args of
    _key:rest -> parseFrom rest >>= parseBy >>= validateGeoSearchOptions
    _         -> Left "GEOSEARCH requires at least key and search clauses"
  where
    parseFrom ("FROMLONLAT":_lon:_lat:tailArgs) = Right tailArgs
    parseFrom ("FROMMEMBER":_member:tailArgs) = Right tailArgs
    parseFrom _ = Left "GEOSEARCH requires FROMLONLAT or FROMMEMBER"

    parseBy ("BYRADIUS":_radius:_unit:tailArgs) = Right tailArgs
    parseBy ("BYBOX":_width:_height:_unit:tailArgs) = Right tailArgs
    parseBy _ = Left "GEOSEARCH requires BYRADIUS or BYBOX"

validateGeoSearchOptions :: [ByteString] -> Either String ()
validateGeoSearchOptions [] = Right ()
validateGeoSearchOptions ("ASC":rest) = validateGeoSearchOptions rest
validateGeoSearchOptions ("DESC":rest) = validateGeoSearchOptions rest
validateGeoSearchOptions ("WITHCOORD":rest) = validateGeoSearchOptions rest
validateGeoSearchOptions ("WITHDIST":rest) = validateGeoSearchOptions rest
validateGeoSearchOptions ("WITHHASH":rest) = validateGeoSearchOptions rest
validateGeoSearchOptions ("COUNT":n:rest) = do
  _ <- parsePositiveInteger "COUNT" n
  case rest of
    "ANY":tailArgs -> validateGeoSearchOptions tailArgs
    _              -> validateGeoSearchOptions rest
validateGeoSearchOptions (token:_) =
  Left $ "Malformed GEOSEARCH option: " ++ BS8.unpack token

validateCopy :: [ByteString] -> Either String ()
validateCopy args =
  case args of
    _source:_dest:rest -> parseCopyOptions rest
    _                  -> Left "COPY requires source and destination keys"
  where
    parseCopyOptions [] = Right ()
    parseCopyOptions ("REPLACE":rest) = parseCopyOptions rest
    parseCopyOptions ("DB":dbNum:rest) = parseNonNegativeInteger "DB" dbNum >> parseCopyOptions rest
    parseCopyOptions (token:_) = Left $ "Malformed COPY option: " ++ BS8.unpack token

breakAtKeyword :: ByteString -> [ByteString] -> Either String ([ByteString], [ByteString])
breakAtKeyword keyword tokens =
  case break (== keyword) tokens of
    (_, [])         -> Left $ "Missing required keyword " ++ BS8.unpack keyword
    (before, after) -> Right (before, after)

parseXReadOptions :: [ByteString] -> Either String ()
parseXReadOptions [] = Right ()
parseXReadOptions ("COUNT":n:rest) = parsePositiveInteger "COUNT" n >> parseXReadOptions rest
parseXReadOptions ("BLOCK":n:rest) = parseNonNegativeInteger "BLOCK" n >> parseXReadOptions rest
parseXReadOptions ("NOACK":rest) = parseXReadOptions rest
parseXReadOptions (token:_) = Left $ "Malformed XREAD option: " ++ BS8.unpack token

sameSlot :: ByteString -> [ByteString] -> Bool
sameSlot firstKey keys =
  let firstSlot = calculateSlot firstKey
  in all (\k -> calculateSlot k == firstSlot) keys

matchCommandSpec :: [ByteString] -> Maybe CommandSpec
matchCommandSpec tokens =
  let matches =
        [ spec
        | spec <- specs
        , map normalizeToken (csTokens spec) `isPrefixOf` tokens
        ]
  in case matches of
       [] -> Nothing
       _  -> Just $ foldl1 longestMatch matches
  where
    longestMatch left right
      | length (csTokens right) > length (csTokens left) = right
      | otherwise = left

normalizeToken :: ByteString -> ByteString
normalizeToken = BS8.map toUpper

parseNonNegativeInteger :: String -> ByteString -> Either String Int
parseNonNegativeInteger label value =
  case BS8.readInt value of
    Just (parsed, rest)
      | BS.null rest && parsed >= 0 -> Right parsed
    _ ->
      Left $ "Invalid " ++ label ++ " value: " ++ BS8.unpack value

parsePositiveInteger :: String -> ByteString -> Either String Int
parsePositiveInteger label value = do
  parsed <- parseNonNegativeInteger label value
  if parsed <= 0
    then Left $ label ++ " must be greater than zero"
    else Right parsed

findIndexFrom :: Int -> (ByteString -> Bool) -> [ByteString] -> Maybe Int
findIndexFrom start predicate tokens =
  fmap fst . find (predicate . snd) $ drop start (zip [0 ..] tokens)

safeTokenAt :: [ByteString] -> Int -> Either String ByteString
safeTokenAt tokens index
  | index < 0 = Left "Computed negative key index from grammar"
  | otherwise =
      case drop index tokens of
        token:_ -> Right token
        []      -> Left "Command does not contain enough arguments for computed key positions"

addPositive :: Int -> Int -> Either String Int
addPositive a b
  | a + b < 0 = Left "Computed negative index in key grammar"
  | otherwise = Right (a + b)

renderTokens :: [ByteString] -> String
renderTokens = BS8.unpack . BS8.unwords

uniqueBytes :: [ByteString] -> [ByteString]
uniqueBytes = nubBy (==)
