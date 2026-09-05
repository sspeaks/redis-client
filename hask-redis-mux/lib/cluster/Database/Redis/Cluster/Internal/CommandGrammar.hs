{-# LANGUAGE OverloadedStrings #-}

-- | Pure Redis command grammar validation and key extraction.
--
-- This module deliberately consumes the generated Redis 7.2 metadata rather
-- than maintaining a second command table.  It is internal because callers
-- should normally use the compatibility facade in
-- "Database.Redis.Cluster.Commands".
module Database.Redis.Cluster.Internal.CommandGrammar
  ( CommandFrameRouting (..)
  , CommandGrammarError (..)
  , classifyCommandFrame
  , renderCommandGrammarError
  ) where

import           Data.ByteString                                 (ByteString)
import qualified Data.ByteString                                 as BS
import qualified Data.ByteString.Char8                           as BS8
import           Data.List                                       (isPrefixOf)
import           Data.Maybe                                      (mapMaybe)
import           Data.Word                                       (Word8)
import           Database.Redis.Cluster                          (calculateSlot)
import           Database.Redis.Cluster.Internal.CommandMetadata

-- | Routing information derived without sending any command to Redis.
data CommandFrameRouting
  = FrameKeyless
  | FrameSingleSlot ByteString [ByteString]
  | FrameCrossSlot [ByteString]
  deriving (Eq, Show)

-- | Precise failures from metadata-driven command analysis.
data CommandGrammarError
  = EmptyCommandFrame
  | UnknownCommand ByteString
  | UnknownSubcommand ByteString ByteString
  | InvalidArity ByteString Int Int
  | MissingRequiredKeyword ByteString ByteString
  | InvalidKeySpec ByteString
  | InvalidKeyCount ByteString
  | UnsupportedKeySpec ByteString
  deriving (Eq, Show)

-- | Validate a complete command frame and classify the slots of every key.
--
-- The first element is the command token and every later element is a raw RESP
-- bulk-string argument.  Command and structural keyword matching is
-- ASCII-case-insensitive; keys are never decoded or transformed.
classifyCommandFrame :: [ByteString] -> Either CommandGrammarError CommandFrameRouting
classifyCommandFrame [] = Left EmptyCommandFrame
classifyCommandFrame frame@(_ : _) = do
  metadata <- resolveCommand frame
  validateArity metadata frame
  keys <- extractKeys metadata frame
  pure $ case keys of
    [] -> FrameKeyless
    firstKey : remainingKeys
      | all ((== calculateSlot firstKey) . calculateSlot) remainingKeys ->
          FrameSingleSlot firstKey keys
      | otherwise -> FrameCrossSlot keys
resolveCommand :: [ByteString] -> Either CommandGrammarError CommandMetadata
resolveCommand frame@(command : _) =
  case longestPrefixMetadata frame of
    Nothing -> Left (UnknownCommand command)
    Just metadata
      | hasUnrecognisedSubcommand metadata frame ->
          Left (UnknownSubcommand (commandIdentity metadata) (frame !! commandTokenCount metadata))
      | otherwise -> Right metadata
resolveCommand [] = Left EmptyCommandFrame

longestPrefixMetadata :: [ByteString] -> Maybe CommandMetadata
longestPrefixMetadata frame =
  foldl choose Nothing (filter (matchesIdentity frame) commandMetadata)
  where
    choose Nothing candidate = Just candidate
    choose current@(Just selected) candidate
      | commandTokenCount candidate > commandTokenCount selected = Just candidate
      | otherwise = current

matchesIdentity :: [ByteString] -> CommandMetadata -> Bool
matchesIdentity frame metadata =
  let identity = identityTokens metadata
  in length frame >= length identity
       && and (zipWith asciiCaseEqual frame identity)

hasUnrecognisedSubcommand :: CommandMetadata -> [ByteString] -> Bool
hasUnrecognisedSubcommand metadata frame =
  let identity = identityTokens metadata
      count = length identity
      hasChildren = any (isStrictChildOf identity) commandMetadata
  in hasChildren
       && length frame > count
       && not (any (matchesIdentity frame) (childCommandsOf identity))

isStrictChildOf :: [ByteString] -> CommandMetadata -> Bool
isStrictChildOf identity candidate =
  let candidateIdentity = identityTokens candidate
  in identity `isPrefixOf` candidateIdentity
       && length candidateIdentity > length identity

childCommandsOf :: [ByteString] -> [CommandMetadata]
childCommandsOf identity = filter (isStrictChildOf identity) commandMetadata

validateArity :: CommandMetadata -> [ByteString] -> Either CommandGrammarError ()
validateArity metadata frame
  | commandArity metadata > 0 && length frame /= commandArity metadata =
      Left (InvalidArity (commandIdentity metadata) (commandArity metadata) (length frame))
  | commandArity metadata < 0 && length frame < negate (commandArity metadata) =
      Left (InvalidArity (commandIdentity metadata) (negate (commandArity metadata)) (length frame))
  | otherwise = Right ()

extractKeys :: CommandMetadata -> [ByteString] -> Either CommandGrammarError [ByteString]
extractKeys metadata frame = do
  extracted <- mapM (extractKeySpec metadata frame) (commandKeySpecs metadata)
  let keys = concat extracted
  if null keys && all isKeywordSpec (commandKeySpecs metadata)
    then case mapMaybe keywordName (commandKeySpecs metadata) of
      keyword : _ -> Left (MissingRequiredKeyword (commandIdentity metadata) keyword)
      [] -> pure keys
    else pure keys

extractKeySpec
  :: CommandMetadata
  -> [ByteString]
  -> KeySpec
  -> Either CommandGrammarError [ByteString]
extractKeySpec metadata frame spec = do
  first <- locateFirstKey metadata frame spec
  keys <- case first of
    Nothing       -> pure []
    Just position -> findKeys metadata frame spec position
  if "INCOMPLETE" `elem` keySpecFlags spec
    then Left (UnsupportedKeySpec (commandIdentity metadata))
    else pure keys

locateFirstKey
  :: CommandMetadata
  -> [ByteString]
  -> KeySpec
  -> Either CommandGrammarError (Maybe Int)
locateFirstKey metadata frame spec =
  case keySpecBeginSearch spec of
    Fixed position
      | position > 0 && position < length frame -> Right (Just position)
      | otherwise -> Left (InvalidKeySpec (commandIdentity metadata))
    Keyword keyword startFrom ->
      Right (keywordPosition frame keyword startFrom)
    UnknownBeginSearch -> Left (UnsupportedKeySpec (commandIdentity metadata))

findKeys
  :: CommandMetadata
  -> [ByteString]
  -> KeySpec
  -> Int
  -> Either CommandGrammarError [ByteString]
findKeys metadata frame spec first =
  case keySpecFindKeys spec of
    Range lastKey step limit ->
      extractRange metadata frame first lastKey step limit
    Keynum keyNumIndex firstKey step ->
      extractKeyNum metadata frame first keyNumIndex firstKey step
    UnknownFindKeys -> Left (UnsupportedKeySpec (commandIdentity metadata))

keywordPosition :: [ByteString] -> ByteString -> Int -> Maybe Int
keywordPosition frame keyword startFrom =
  let argumentCount = length frame
      start = if startFrom > 0 then startFrom else argumentCount + startFrom
      end = if startFrom > 0 then argumentCount - 1 else 1
      increment = if start <= end then 1 else -1
      positions = takeWhile (/= end) [start, start + increment ..]
  in (+ 1) <$> findFirst (\position -> inArgumentBounds frame position
                              && asciiCaseEqual (frame !! position) keyword) positions

findFirst :: (a -> Bool) -> [a] -> Maybe a
findFirst predicate = go
  where
    go [] = Nothing
    go (value : values)
      | predicate value = Just value
      | otherwise = go values

extractRange
  :: CommandMetadata
  -> [ByteString]
  -> Int
  -> Int
  -> Int
  -> Int
  -> Either CommandGrammarError [ByteString]
extractRange metadata frame first lastKey step limit
  | step <= 0 || limit < 0 = Left (InvalidKeySpec (commandIdentity metadata))
  | lastKey < -1 && limit /= 0 = Left (InvalidKeySpec (commandIdentity metadata))
  | limit > 0 && (length frame - first) `mod` limit /= 0 =
      Left (InvalidKeySpec (commandIdentity metadata))
  | otherwise =
      let lastPosition
            | lastKey >= 0 = first + lastKey
            | limit == 0 = length frame + lastKey
            | otherwise = first + ((length frame - first) `div` limit + lastKey)
      in keysAtPositions metadata frame [first, first + step .. lastPosition]

extractKeyNum
  :: CommandMetadata
  -> [ByteString]
  -> Int
  -> Int
  -> Int
  -> Int
  -> Either CommandGrammarError [ByteString]
extractKeyNum metadata frame first keyNumIndex firstKey step
  | step <= 0 = Left (InvalidKeySpec (commandIdentity metadata))
  | not (inFrameBounds frame keyCountPosition) =
      Left (InvalidKeySpec (commandIdentity metadata))
  | otherwise =
      case parseNonNegativeDecimal (frame !! keyCountPosition) of
        Nothing -> Left (InvalidKeyCount (commandIdentity metadata))
        Just keyCount
          | keyCount == 0 -> Right []
          | otherwise ->
              let firstPosition = first + firstKey
                  lastPosition = firstPosition + keyCount - 1
              in keysAtPositions metadata frame [firstPosition, firstPosition + step .. lastPosition]
  where
    keyCountPosition = first + keyNumIndex

keysAtPositions
  :: CommandMetadata
  -> [ByteString]
  -> [Int]
  -> Either CommandGrammarError [ByteString]
keysAtPositions metadata frame positions
  | null positions = Left (InvalidKeySpec (commandIdentity metadata))
  | all (inFrameBounds frame) positions = Right (map (frame !!) positions)
  | otherwise = Left (InvalidKeySpec (commandIdentity metadata))

parseNonNegativeDecimal :: ByteString -> Maybe Int
parseNonNegativeDecimal value
  | BS.null value || not (BS.all isDecimalDigit value) = Nothing
  | otherwise =
      let parsed = BS.foldl' (\number digit -> number * 10 + fromIntegral (digit - 48)) (0 :: Integer) value
      in if parsed > fromIntegral (maxBound :: Int)
           then Nothing
           else Just (fromIntegral parsed)

isDecimalDigit :: Word8 -> Bool
isDecimalDigit byte = byte >= 48 && byte <= 57

isKeywordSpec :: KeySpec -> Bool
isKeywordSpec spec =
  case keySpecBeginSearch spec of
    Keyword _ _ -> True
    _           -> False

keywordName :: KeySpec -> Maybe ByteString
keywordName spec =
  case keySpecBeginSearch spec of
    Keyword name _ -> Just name
    _              -> Nothing

identityTokens :: CommandMetadata -> [ByteString]
identityTokens = BS8.split ' ' . commandIdentity

commandTokenCount :: CommandMetadata -> Int
commandTokenCount = length . identityTokens

inFrameBounds :: [a] -> Int -> Bool
inFrameBounds frame position = position >= 0 && position < length frame

inArgumentBounds :: [a] -> Int -> Bool
inArgumentBounds frame position = position >= 1 && position < length frame

asciiCaseEqual :: ByteString -> ByteString -> Bool
asciiCaseEqual left right = BS.map asciiToUpper left == BS.map asciiToUpper right

asciiToUpper :: Word8 -> Word8
asciiToUpper byte
  | byte >= 97 && byte <= 122 = byte - 32
  | otherwise = byte

renderCommandGrammarError :: CommandGrammarError -> String
renderCommandGrammarError errorValue =
  case errorValue of
    EmptyCommandFrame -> "empty command frame"
    UnknownCommand _ -> "unknown command"
    UnknownSubcommand command _ -> "unknown subcommand for " ++ BS8.unpack command
    InvalidArity command expected actual ->
      BS8.unpack command ++ " has invalid arity: expected "
        ++ show expected ++ " argument(s), got " ++ show actual
    MissingRequiredKeyword command keyword ->
      BS8.unpack command ++ " requires " ++ BS8.unpack keyword
    InvalidKeySpec command ->
      BS8.unpack command ++ " has malformed key arguments"
    InvalidKeyCount command ->
      BS8.unpack command ++ " has an invalid key count"
    UnsupportedKeySpec command ->
      BS8.unpack command ++ " uses an unsupported dynamic key specification"
