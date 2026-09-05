{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands
  ( keylessCommands,
    requiresKeyCommands,
    commandSpecCount,
    commandSourceSha,
    CommandRouting (..),
    classifyCommand,
    classifyCommandResp,
    extractCommandTokens,
  )
where

import           Data.ByteString                           (ByteString)
import qualified Data.ByteString.Char8                     as BS8
import qualified Data.Map.Strict                           as Map
import           Data.Maybe                                (fromMaybe,
                                                            listToMaybe)
import           Data.Set                                  (Set)
import qualified Data.Set                                  as Set
import           Data.Word                                 (Word16)
import           Database.Redis.Cluster                    (calculateSlot)
import           Database.Redis.Cluster.Commands.Generated
import           Database.Redis.Resp                       (RespData (..))

-- | Result of classifying a command for cluster routing.
data CommandRouting
  = KeylessRoute
  | KeyedRoute ByteString
  | CommandError String
  deriving (Eq, Show)

commandSourceSha :: ByteString
commandSourceSha = redisDocSha

commandSpecCount :: Int
commandSpecCount = length generatedRoutingEntries

keylessCommands :: [ByteString]
keylessCommands =
  [ BS8.unwords (greTokens entry)
  | entry <- generatedRoutingEntries
  , greKeySpec entry == Nothing
  ]

requiresKeyCommands :: [ByteString]
requiresKeyCommands =
  [ BS8.unwords (greTokens entry)
  | entry <- generatedRoutingEntries
  , greKeySpec entry /= Nothing
  ]

classifyCommand :: ByteString -> [ByteString] -> CommandRouting
classifyCommand cmd args =
  classifyCommandResp (RespArray (map RespBulkString (cmd : args)))

classifyCommandResp :: RespData -> CommandRouting
classifyCommandResp resp =
  case extractCommandTokens resp of
    Left err -> CommandError err
    Right tokenized ->
      case pickEntry tokenized of
        Left err -> CommandError err
        Right entry ->
          case enforceArity entry tokenized of
            Left err -> CommandError err
            Right () ->
              case extractRoutingKeys entry tokenized of
                Left err -> CommandError err
                Right keys ->
                  toRouting entry keys

extractCommandTokens :: RespData -> Either String [ByteString]
extractCommandTokens (RespArray items)
  | null items = Left "Empty command"
  | otherwise = mapM toToken items
extractCommandTokens _ = Left "Expected RESP array command"

pickEntry :: [ByteString] -> Either String GeneratedRoutingEntry
pickEntry tokens =
  case candidates of
    [] ->
      case tokens of
        [] -> Left "Empty command"
        (cmd : rest)
          | hasSubcommands cmd && not (null rest) ->
              Left $ "ERR unsupported subcommand for " ++ BS8.unpack cmd
          | otherwise -> Left $ "ERR unknown command " ++ BS8.unpack cmd
    _  -> Right $ maximumByTokenCount candidates
  where
    candidates =
      [ entry
      | entry <- generatedRoutingEntries
      , isPrefixTokens (greTokens entry) tokens
      ]

    hasSubcommands cmd = Set.member (normalize cmd) subcommandRoots

subcommandRoots :: Set ByteString
subcommandRoots =
  Set.fromList
    [ normalize root
    | entry <- generatedRoutingEntries
    , root : rest <- [greTokens entry]
    , not (null rest)
    ]

maximumByTokenCount :: [GeneratedRoutingEntry] -> GeneratedRoutingEntry
maximumByTokenCount =
  foldl1
    (\acc next -> if length (greTokens next) > length (greTokens acc) then next else acc)

isPrefixTokens :: [ByteString] -> [ByteString] -> Bool
isPrefixTokens prefixTokens allTokens =
  length prefixTokens <= length allTokens
    && and (zipWith tokenEq prefixTokens allTokens)

enforceArity :: GeneratedRoutingEntry -> [ByteString] -> Either String ()
enforceArity entry args
  | expected > 0 && argc /= expected =
      Left $ "ERR wrong number of arguments for " ++ prettyName ++ " command"
  | expected < 0 && argc < negate expected =
      Left $ "ERR wrong number of arguments for " ++ prettyName ++ " command"
  | otherwise = Right ()
  where
    expected = greArity entry
    argc = length args
    prettyName = BS8.unpack $ BS8.unwords (greTokens entry)

toRouting :: GeneratedRoutingEntry -> [ByteString] -> CommandRouting
toRouting _ [] = KeylessRoute
toRouting _ (key : rest)
  | null rest = KeyedRoute key
  | allSameSlot (key : rest) = KeyedRoute key
  | otherwise = CommandError "ERR CROSSSLOT Keys in request do not hash to the same slot"

allSameSlot :: [ByteString] -> Bool
allSameSlot [] = True
allSameSlot (firstKey : rest) =
  let firstSlot = calculateSlot firstKey
  in all (== firstSlot) (map calculateSlot rest)

extractRoutingKeys :: GeneratedRoutingEntry -> [ByteString] -> Either String [ByteString]
extractRoutingKeys entry args =
  case greSyntax entry of
    SyntaxPairs      -> extractPairsKeys entry args
    SyntaxEval       -> extractEvalKeys entry args
    SyntaxXRead      -> extractXReadKeys args
    SyntaxXReadGroup -> extractXReadGroupKeys args
    SyntaxNone       -> extractByKeySpec entry args

extractPairsKeys :: GeneratedRoutingEntry -> [ByteString] -> Either String [ByteString]
extractPairsKeys entry args =
  let start = length (greTokens entry)
      payload = drop start args
  in if null payload || odd (length payload)
       then Left "ERR wrong number of arguments for pair-form command"
       else Right [key | (key, idx) <- zip payload [0 :: Int ..], even idx]

extractEvalKeys :: GeneratedRoutingEntry -> [ByteString] -> Either String [ByteString]
extractEvalKeys entry args =
  let prefixLen = length (greTokens entry)
      payload = drop prefixLen args
  in case payload of
       (_script : keyCount : rest) ->
         case parseNonNegativeInt keyCount of
           Nothing -> Left "ERR invalid numkeys for script command"
           Just numKeys
             | numKeys > length rest -> Left "ERR wrong number of arguments for script command"
             | otherwise -> Right (take numKeys rest)
       _ -> Left "ERR wrong number of arguments for script command"

extractXReadKeys :: [ByteString] -> Either String [ByteString]
extractXReadKeys args = do
  let payload = drop 1 args
  streamsIndex <- parseXReadPreamble payload
  parseStreamPairs (drop (streamsIndex + 1) payload)

extractXReadGroupKeys :: [ByteString] -> Either String [ByteString]
extractXReadGroupKeys args = do
  payload <- case drop 1 args of
    groupToken : _group : _consumer : rest
      | tokenEq groupToken "GROUP" -> Right rest
      | otherwise -> Left "ERR XREADGROUP requires GROUP <group> <consumer>"
    _ -> Left "ERR XREADGROUP requires GROUP <group> <consumer>"
  streamsIndex <- parseXReadOptions payload
  parseStreamPairs (drop (streamsIndex + 1) payload)

parseXReadPreamble :: [ByteString] -> Either String Int
parseXReadPreamble payload =
  parseUntilStreams Set.empty 0 payload
  where
    parseUntilStreams _ index [] = Left "ERR XREAD requires STREAMS"
    parseUntilStreams seen index (tok : rest)
      | tokenEq tok "STREAMS" = Right index
      | tokenEq tok "COUNT" = requireIntOption seen "COUNT" index rest
      | tokenEq tok "BLOCK" = requireIntOption seen "BLOCK" index rest
      | otherwise = Left "ERR invalid XREAD option"

    requireIntOption seen opt index rest
      | Set.member opt seen = Left "ERR duplicate XREAD option"
      | otherwise = case rest of
          (value : tailValues)
            | parseNonNegativeInt value /= Nothing ->
                parseUntilStreams (Set.insert opt seen) (index + 2) tailValues
            | otherwise -> Left "ERR invalid XREAD numeric option"
          _ -> Left "ERR missing XREAD option value"

parseXReadOptions :: [ByteString] -> Either String Int
parseXReadOptions payload = go Set.empty 0 payload
  where
    go _ idx [] = Left "ERR XREADGROUP requires STREAMS"
    go seen idx (tok : rest)
      | tokenEq tok "STREAMS" = Right idx
      | tokenEq tok "NOACK" =
          if Set.member "NOACK" seen
            then Left "ERR duplicate XREADGROUP option"
            else go (Set.insert "NOACK" seen) (idx + 1) rest
      | tokenEq tok "COUNT" || tokenEq tok "BLOCK" =
          if Set.member (normalize tok) seen
            then Left "ERR duplicate XREADGROUP option"
            else case rest of
              (value : tailValues)
                | parseNonNegativeInt value /= Nothing ->
                    go (Set.insert (normalize tok) seen) (idx + 2) tailValues
                | otherwise -> Left "ERR invalid XREADGROUP numeric option"
              _ -> Left "ERR missing XREADGROUP option value"
      | otherwise = Left "ERR invalid XREADGROUP option"

parseStreamPairs :: [ByteString] -> Either String [ByteString]
parseStreamPairs payload
  | length payload < 2 = Left "ERR STREAMS requires at least one key and one id"
  | odd (length payload) = Left "ERR STREAMS keys and IDs count mismatch"
  | otherwise =
      let half = length payload `div` 2
          keys = take half payload
      in if null keys then Left "ERR STREAMS requires at least one key" else Right keys

extractByKeySpec :: GeneratedRoutingEntry -> [ByteString] -> Either String [ByteString]
extractByKeySpec entry args =
  case greKeySpec entry of
    Nothing -> Right []
    Just spec -> do
      start <- resolveBegin (gksBegin spec) args
      resolveKeysFrom start (gksFind spec) args

resolveBegin :: GeneratedBeginSearch -> [ByteString] -> Either String Int
resolveBegin (BeginAtIndex idx) _ = Right idx
resolveBegin (BeginAfterKeyword keyword startFrom) args =
  case findKeywordIndex keyword startFrom args of
    Nothing  -> Left $ "ERR missing required keyword " ++ BS8.unpack keyword
    Just idx -> Right idx

resolveKeysFrom :: Int -> GeneratedFindKeys -> [ByteString] -> Either String [ByteString]
resolveKeysFrom start findSpec args =
  case findSpec of
    FindRange lastKey step limit ->
      extractRangeKeys start lastKey step limit args
    FindKeyNum keyNumIdx firstKey step ->
      extractKeyNumKeys start keyNumIdx firstKey step args

extractRangeKeys :: Int -> Int -> Int -> Int -> [ByteString] -> Either String [ByteString]
extractRangeKeys start lastKey step limit args
  | step <= 0 = Left "ERR invalid key step in routing metadata"
  | otherwise =
      let endIndex =
            if lastKey >= 0
              then start + lastKey
              else length args + lastKey
          boundedEnd =
            if limit > 0
              then min endIndex (start + limit - 1)
              else endIndex
          indexes = [start, start + step .. boundedEnd]
          keys = [value | i <- indexes, Just value <- [indexMaybe i args]]
      in if null keys then Right [] else Right keys

extractKeyNumKeys :: Int -> Int -> Int -> Int -> [ByteString] -> Either String [ByteString]
extractKeyNumKeys start keyNumIdx firstKey step args
  | step <= 0 = Left "ERR invalid key step in routing metadata"
  | otherwise =
      case indexMaybe (start + keyNumIdx) args of
        Nothing -> Left "ERR missing key count argument"
        Just countToken ->
          case parseNonNegativeInt countToken of
            Nothing -> Left "ERR invalid key count argument"
            Just keyCount ->
              let firstIndex = start + firstKey
                  indexes = take keyCount [firstIndex, firstIndex + step ..]
                  keys = [value | i <- indexes, Just value <- [indexMaybe i args]]
              in if length keys /= keyCount
                   then Left "ERR wrong number of key arguments"
                   else Right keys

findKeywordIndex :: ByteString -> Int -> [ByteString] -> Maybe Int
findKeywordIndex keyword startFrom args =
  let start = max 0 startFrom
      indexed = zip [start ..] (drop start args)
  in fst <$> listToMaybe [pair | pair@(_, token) <- indexed, tokenEq keyword token]

parseNonNegativeInt :: ByteString -> Maybe Int
parseNonNegativeInt bs =
  case BS8.readInt bs of
    Just (n, "") | n >= 0 -> Just n
    _                     -> Nothing

tokenEq :: ByteString -> ByteString -> Bool
tokenEq a b = normalize a == normalize b

normalize :: ByteString -> ByteString
normalize = BS8.map toUpperAscii

toUpperAscii :: Char -> Char
toUpperAscii c
  | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
  | otherwise = c

indexMaybe :: Int -> [a] -> Maybe a
indexMaybe idx values
  | idx < 0 = Nothing
  | otherwise =
      if idx >= length values then Nothing else Just (values !! idx)

toToken :: RespData -> Either String ByteString
toToken (RespBulkString bs)   = Right bs
toToken (RespSimpleString bs) = Right bs
toToken _ = Left "ERR command arguments must be bulk or simple strings"
