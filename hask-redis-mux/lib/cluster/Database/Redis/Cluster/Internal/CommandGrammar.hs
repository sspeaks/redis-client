{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings        #-}

{- | Pure Redis command grammar validation and key extraction.

The generated metadata preserves the Redis 7.2 argument grammar as well as
its key specifications. A frame is routable only when one complete argument
parse agrees with every selected key specification.
-}
module Database.Redis.Cluster.Internal.CommandGrammar (
    CommandFrameRouting (..),
    CommandGrammarError (..),
    classifyCommandFrame,
    renderCommandGrammarError,
) where

import           Data.ByteString                                 (ByteString)
import qualified Data.ByteString                                 as BS
import qualified Data.ByteString.Char8                           as BS8
import           Data.Int                                        (Int64)
import           Data.IntMap.Strict                              (IntMap)
import qualified Data.IntMap.Strict                              as IntMap
import           Data.List                                       (find, nub)
import qualified Data.Map.Strict                                 as Map
import           Data.Maybe                                      (mapMaybe)
import           Data.Word                                       (Word8)
import           Database.Redis.Cluster                          (calculateSlot)
import           Database.Redis.Cluster.Internal.CommandMetadata
import           Foreign.C.Error                                 (eRANGE,
                                                                  getErrno,
                                                                  resetErrno)
import           Foreign.C.String                                (CString)
import           Foreign.C.Types                                 (CDouble (..))
import           Foreign.Marshal.Alloc                           (alloca)
import           Foreign.Ptr                                     (Ptr, minusPtr)
import           Foreign.Storable                                (peek)
import           System.IO.Unsafe                                (unsafePerformIO)

foreign import ccall unsafe "stdlib.h strtod"
    c_strtod :: CString -> Ptr CString -> IO CDouble

data CommandFrameRouting
    = FrameKeyless
    | FrameSingleSlot ByteString [ByteString]
    | FrameCrossSlot [ByteString]
    deriving (Eq, Show)

data CommandGrammarError
    = EmptyCommandFrame
    | UnknownCommand ByteString
    | UnknownSubcommand ByteString ByteString
    | InvalidArity ByteString Int Int
    | MissingRequiredKeyword ByteString ByteString
    | InvalidArguments ByteString
    | InvalidKeySpec ByteString
    | InvalidKeyCount ByteString
    | UnsupportedKeySpec ByteString
    deriving (Eq, Show)

data ParseState = ParseState
    { parsePosition     :: !Int
    , parseKeyPositions :: !(IntMap [Int])
    }
    deriving (Eq, Ord, Show)

classifyCommandFrame :: [ByteString] -> Either CommandGrammarError CommandFrameRouting
classifyCommandFrame [] = Left EmptyCommandFrame
classifyCommandFrame frame@(_ : _) = do
    metadata <- resolveCommand frame
    validateArity metadata frame
    validateKeyNumCounts metadata frame
    keys <- validateArgumentsAndExtractKeys metadata frame
    pure $ case keys of
        [] -> FrameKeyless
        firstKey : remainingKeys
            | all ((== calculateSlot firstKey) . calculateSlot) remainingKeys ->
                FrameSingleSlot firstKey keys
            | otherwise -> FrameCrossSlot keys

resolveCommand :: [ByteString] -> Either CommandGrammarError CommandMetadata
resolveCommand [] = Left EmptyCommandFrame
resolveCommand (command : arguments) =
    case Map.lookup commandName commandMetadataByIdentity of
        Nothing -> Left (UnknownCommand command)
        Just parent ->
            case arguments of
                subcommand : _
                    | commandHasSubcommands parent ->
                        case Map.lookup
                            (commandName <> " " <> asciiUpper subcommand)
                            commandMetadataByIdentity of
                            Just child -> Right child
                            Nothing -> Left (UnknownSubcommand commandName subcommand)
                _ -> Right parent
  where
    commandName = asciiUpper command

validateArity :: CommandMetadata -> [ByteString] -> Either CommandGrammarError ()
validateArity metadata frame
    | commandArity metadata > 0 && length frame /= commandArity metadata =
        Left (InvalidArity (commandIdentity metadata) (commandArity metadata) (length frame))
    | commandArity metadata < 0 && length frame < negate (commandArity metadata) =
        Left (InvalidArity (commandIdentity metadata) (negate (commandArity metadata)) (length frame))
    | otherwise = Right ()

validateKeyNumCounts ::
    CommandMetadata ->
    [ByteString] ->
    Either CommandGrammarError ()
validateKeyNumCounts metadata frame =
    mapM_ validateSpec (commandKeySpecs metadata)
  where
    validateSpec spec =
        case keySpecFindKeys spec of
            Keynum keyNumIndex _ _ -> do
                first <- locateFirstKey metadata frame spec
                case first >>= valueAt frame . (+ keyNumIndex) of
                    Nothing -> Left (InvalidKeySpec (commandIdentity metadata))
                    Just value ->
                        case parseNonNegativeDecimal value of
                            Nothing -> Left (InvalidKeyCount (commandIdentity metadata))
                            Just 0
                                | "NO_MANDATORY_KEYS" `notElem` commandFlags metadata ->
                                    Left (InvalidKeyCount (commandIdentity metadata))
                            Just _ -> Right ()
            _ -> Right ()

validateArgumentsAndExtractKeys ::
    CommandMetadata ->
    [ByteString] ->
    Either CommandGrammarError [ByteString]
validateArgumentsAndExtractKeys metadata frame
    | null (commandArguments metadata) =
        extractKeysForParse metadata frame (ParseState identityLength IntMap.empty)
    | otherwise =
        case validResults of
            keys : _ -> Right keys
            [] ->
                case firstFailure of
                    Just failure -> Left failure
                    Nothing ->
                        case missingRequiredKeyword metadata frame of
                            Just keyword ->
                                Left (MissingRequiredKeyword (commandIdentity metadata) keyword)
                            Nothing -> Left (InvalidArguments (commandIdentity metadata))
  where
    identityLength = commandTokenCount metadata
    initial = ParseState identityLength IntMap.empty
    completeParses =
        filter ((== length frame) . parsePosition) $
            parseSequence frame (commandArguments metadata) initial
    outcomes = map (extractKeysForParse metadata frame) completeParses
    validResults = [keys | Right keys <- outcomes]
    firstFailure = case [failure | Left failure <- outcomes] of
        failure : _ -> Just failure
        []          -> Nothing

parseSequence :: [ByteString] -> [CommandArgument] -> ParseState -> [ParseState]
parseSequence _ [] state = [state]
parseSequence frame (argument : remaining) state =
    uniqueStates $
        concatMap (parseSequence frame remaining) (parseArgument frame argument state)

parseArgument :: [ByteString] -> CommandArgument -> ParseState -> [ParseState]
parseArgument frame argument state =
    uniqueStates $ optionalResult <> requiredResults
  where
    optionalResult = [state | argumentOptional argument]
    requiredResults
        | argumentMultiple argument =
            if argumentMultipleToken argument
                then repeatOneOrMore (parseOneWithToken frame argument) state
                else
                    concatMap
                        (repeatOneOrMore (parsePayload frame argument))
                        (consumeOuterToken frame argument state)
        | otherwise = parseOneWithToken frame argument state

parseOneWithToken ::
    [ByteString] ->
    CommandArgument ->
    ParseState ->
    [ParseState]
parseOneWithToken frame argument state =
    concatMap
        (parsePayload frame argument)
        (consumeOuterToken frame argument state)

consumeOuterToken ::
    [ByteString] ->
    CommandArgument ->
    ParseState ->
    [ParseState]
consumeOuterToken frame argument state
    | argumentKind argument == ArgumentPureToken = [state]
    | otherwise =
        case argumentToken argument of
            Nothing    -> [state]
            Just token -> consumeToken frame token state

parsePayload ::
    [ByteString] ->
    CommandArgument ->
    ParseState ->
    [ParseState]
parsePayload frame argument state =
    case argumentKind argument of
        ArgumentString -> consumeScalar (const True)
        ArgumentInteger -> consumeScalar isSignedInteger
        ArgumentDouble -> consumeScalar isDouble
        ArgumentUnixTime -> consumeScalar isSignedInteger
        ArgumentKey -> consumeScalar (const True)
        ArgumentPattern -> consumeScalar (const True)
        ArgumentPureToken ->
            case argumentToken argument of
                Just token -> consumeToken frame token state
                Nothing    -> []
        ArgumentOneOf alternatives ->
            let tokenResults =
                    uniqueStates $
                        concatMap
                            (\choice -> progressing state (parseArgument frame choice state))
                            (filter isTokenDirected alternatives)
             in if null tokenResults
                    then
                        uniqueStates $
                            concatMap
                                (\choice -> progressing state (parseArgument frame choice state))
                                (filter (not . isTokenDirected) alternatives)
                    else tokenResults
        ArgumentBlock arguments ->
            parseSequence frame arguments state
  where
    consumeScalar predicate =
        case valueAt frame (parsePosition state) of
            Just value
                | predicate value ->
                    [ recordArgumentKey argument (parsePosition state) $
                        state{parsePosition = parsePosition state + 1}
                    ]
            _ -> []

repeatOneOrMore ::
    (ParseState -> [ParseState]) ->
    ParseState ->
    [ParseState]
repeatOneOrMore parseOne initial =
    go [] (progressing initial (parseOne initial))
  where
    go results [] = uniqueStates results
    go results frontier =
        let next =
                uniqueStates $
                    concatMap (\state -> progressing state (parseOne state)) frontier
         in go (results <> frontier) next

progressing :: ParseState -> [ParseState] -> [ParseState]
progressing previous =
    filter ((> parsePosition previous) . parsePosition)

recordArgumentKey :: CommandArgument -> Int -> ParseState -> ParseState
recordArgumentKey argument position state =
    case argumentKeySpecIndex argument of
        Nothing -> state
        Just index ->
            state
                { parseKeyPositions =
                    IntMap.insertWith
                        (flip (<>))
                        index
                        [position]
                        (parseKeyPositions state)
                }

consumeToken :: [ByteString] -> ByteString -> ParseState -> [ParseState]
consumeToken frame token state =
    case valueAt frame (parsePosition state) of
        Just value
            | tokenMatches value token ->
                [state{parsePosition = parsePosition state + 1}]
        _ -> []

tokenMatches :: ByteString -> ByteString -> Bool
tokenMatches value token
    | token == "\"\"" = BS.null value
    | otherwise = asciiCaseEqual value token

uniqueStates :: [ParseState] -> [ParseState]
uniqueStates = nub

isTokenDirected :: CommandArgument -> Bool
isTokenDirected argument =
    argumentKind argument == ArgumentPureToken
        || argumentToken argument /= Nothing

extractKeysForParse ::
    CommandMetadata ->
    [ByteString] ->
    ParseState ->
    Either CommandGrammarError [ByteString]
extractKeysForParse metadata frame parsed = do
    extracted <- mapM extractActiveSpec indexedSpecs
    let keys = concat extracted
        requiresRealKey =
            any ("NOT_KEY" `notElem`) (map keySpecFlags $ commandKeySpecs metadata)
    if null keys
        && requiresRealKey
        && "NO_MANDATORY_KEYS" `notElem` commandFlags metadata
        then Left (InvalidKeySpec (commandIdentity metadata))
        else pure keys
  where
    indexedSpecs = zip [0 ..] (commandKeySpecs metadata)
    linkedIndices = linkedKeySpecIndices (commandArguments metadata)

    extractActiveSpec (index, spec)
        | shouldEvaluate index spec = do
            keys <- extractKeySpec metadata frame spec
            validateKeyCountPolicy metadata spec keys
            case IntMap.lookup index (parseKeyPositions parsed) of
                Nothing -> pure keys
                Just positions
                    | mapMaybe (valueAt frame) positions == keys -> pure keys
                    | otherwise -> Left (InvalidKeySpec (commandIdentity metadata))
        | otherwise = pure []

    shouldEvaluate index spec =
        IntMap.member index (parseKeyPositions parsed)
            || isKeynumSpec spec
            || (index `notElem` linkedIndices && beginSearchPresent frame spec)

validateKeyCountPolicy ::
    CommandMetadata ->
    KeySpec ->
    [ByteString] ->
    Either CommandGrammarError ()
validateKeyCountPolicy metadata spec keys
    | isKeynumSpec spec
        && null keys
        && "NO_MANDATORY_KEYS" `notElem` commandFlags metadata =
        Left (InvalidKeyCount (commandIdentity metadata))
    | otherwise = Right ()

extractKeySpec ::
    CommandMetadata ->
    [ByteString] ->
    KeySpec ->
    Either CommandGrammarError [ByteString]
extractKeySpec metadata frame spec
    | "INCOMPLETE" `elem` keySpecFlags spec =
        Left (UnsupportedKeySpec (commandIdentity metadata))
    | otherwise = do
        first <- locateFirstKey metadata frame spec
        case first of
            Nothing       -> pure []
            Just position -> findKeys metadata frame spec position

locateFirstKey ::
    CommandMetadata ->
    [ByteString] ->
    KeySpec ->
    Either CommandGrammarError (Maybe Int)
locateFirstKey metadata frame spec =
    case keySpecBeginSearch spec of
        Fixed position
            | position > 0 && position < length frame -> Right (Just position)
            | otherwise -> Left (InvalidKeySpec (commandIdentity metadata))
        Keyword keyword startFrom ->
            Right (keywordPosition frame keyword startFrom)
        UnknownBeginSearch -> Left (UnsupportedKeySpec (commandIdentity metadata))

findKeys ::
    CommandMetadata ->
    [ByteString] ->
    KeySpec ->
    Int ->
    Either CommandGrammarError [ByteString]
findKeys metadata frame spec first =
    case keySpecFindKeys spec of
        Range lastKey step limit ->
            extractRange metadata frame first lastKey step limit
        Keynum keyNumIndex firstKey step ->
            extractKeyNum metadata frame first keyNumIndex firstKey step
        UnknownFindKeys -> Left (UnsupportedKeySpec (commandIdentity metadata))

keywordPosition :: [ByteString] -> ByteString -> Int -> Maybe Int
keywordPosition frame keyword startFrom =
    (+ 1)
        <$> find
            ( \position ->
                inArgumentBounds frame position
                    && asciiCaseEqual (frame !! position) keyword
            )
            positions
  where
    argumentCount = length frame
    start = if startFrom > 0 then startFrom else argumentCount + startFrom
    positions
        | startFrom > 0 = [start .. argumentCount - 2]
        | otherwise = [start, start - 1 .. 1]

extractRange ::
    CommandMetadata ->
    [ByteString] ->
    Int ->
    Int ->
    Int ->
    Int ->
    Either CommandGrammarError [ByteString]
extractRange metadata frame first lastKey step limit
    | step <= 0 || limit < 0 = Left invalid
    | lastKey < -1 && limit /= 0 = Left invalid
    | limit > 0 && (length frame - first) `mod` limit /= 0 = Left invalid
    | otherwise =
        let lastPosition
                | lastKey >= 0 = first + lastKey
                | limit == 0 = length frame + lastKey
                | otherwise = first + ((length frame - first) `div` limit + lastKey)
         in keysAtPositions metadata frame [first, first + step .. lastPosition]
  where
    invalid = InvalidKeySpec (commandIdentity metadata)

extractKeyNum ::
    CommandMetadata ->
    [ByteString] ->
    Int ->
    Int ->
    Int ->
    Int ->
    Either CommandGrammarError [ByteString]
extractKeyNum metadata frame first keyNumIndex firstKey step
    | step <= 0 = Left invalid
    | not (inFrameBounds frame keyCountPosition) = Left invalid
    | otherwise =
        case parseNonNegativeDecimal (frame !! keyCountPosition) of
            Nothing -> Left (InvalidKeyCount (commandIdentity metadata))
            Just keyCount
                | keyCount == 0 -> Right []
                | keyCount > maximumCount -> Left invalid
                | otherwise ->
                    let firstPosition = first + firstKey
                        positions =
                            take keyCount [firstPosition, firstPosition + step ..]
                     in keysAtPositions metadata frame positions
  where
    invalid = InvalidKeySpec (commandIdentity metadata)
    keyCountPosition = first + keyNumIndex
    maximumCount
        | first + firstKey < 0 = 0
        | otherwise =
            max 0 ((length frame - 1 - (first + firstKey)) `div` max 1 step + 1)

keysAtPositions ::
    CommandMetadata ->
    [ByteString] ->
    [Int] ->
    Either CommandGrammarError [ByteString]
keysAtPositions metadata frame positions
    | null positions = Left (InvalidKeySpec (commandIdentity metadata))
    | all (inFrameBounds frame) positions = Right (map (frame !!) positions)
    | otherwise = Left (InvalidKeySpec (commandIdentity metadata))

parseNonNegativeDecimal :: ByteString -> Maybe Int
parseNonNegativeDecimal value
    | BS.null value || not (BS.all isDecimalDigit value) = Nothing
    | otherwise =
        let parsed =
                BS.foldl'
                    (\number digit -> number * 10 + fromIntegral (digit - 48))
                    (0 :: Integer)
                    value
         in if parsed > fromIntegral (maxBound :: Int)
                then Nothing
                else Just (fromIntegral parsed)

isSignedInteger :: ByteString -> Bool
isSignedInteger value =
    case reads (BS8.unpack value) :: [(Integer, String)] of
        [(parsed, "")] ->
            parsed >= fromIntegral (minBound :: Int64)
                && parsed <= fromIntegral (maxBound :: Int64)
        _ -> False

-- Redis 7.2 validates doubles with strtod, including forms such as .5 and 1.
isDouble :: ByteString -> Bool
isDouble value
    | BS.null value || isAsciiSpace (BS.head value) = False
    | otherwise = unsafePerformIO $
        BS.useAsCStringLen value $ \(start, length') ->
            alloca $ \endPointer -> do
                resetErrno
                CDouble parsed <- c_strtod start endPointer
                errno <- getErrno
                end <- peek endPointer
                pure $
                    end `minusPtr` start == length'
                        && not (isNaN parsed)
                        && not (errno == eRANGE && (isInfinite parsed || parsed == 0))
{-# NOINLINE isDouble #-}

isAsciiSpace :: Word8 -> Bool
isAsciiSpace byte = byte == 32 || (byte >= 9 && byte <= 13)

isKeynumSpec :: KeySpec -> Bool
isKeynumSpec spec =
    case keySpecFindKeys spec of
        Keynum _ _ _ -> True
        _            -> False

beginSearchPresent :: [ByteString] -> KeySpec -> Bool
beginSearchPresent frame spec =
    case keySpecBeginSearch spec of
        Fixed position       -> inArgumentBounds frame position
        Keyword keyword from -> keywordPosition frame keyword from /= Nothing
        UnknownBeginSearch   -> True

linkedKeySpecIndices :: [CommandArgument] -> [Int]
linkedKeySpecIndices = nub . concatMap go
  where
    go argument =
        maybe [] pure (argumentKeySpecIndex argument)
            <> case argumentKind argument of
                ArgumentOneOf children -> linkedKeySpecIndices children
                ArgumentBlock children -> linkedKeySpecIndices children
                _                      -> []

missingRequiredKeyword :: CommandMetadata -> [ByteString] -> Maybe ByteString
missingRequiredKeyword metadata frame
    | null specs || not (all isKeywordSpec specs) = Nothing
    | otherwise =
        find
            (\keyword -> not (any (asciiCaseEqual keyword) frame))
            (mapMaybe keywordName specs)
  where
    specs = commandKeySpecs metadata

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

commandTokenCount :: CommandMetadata -> Int
commandTokenCount =
    length . BS8.split ' ' . commandIdentity

valueAt :: [a] -> Int -> Maybe a
valueAt values position
    | position < 0 = Nothing
    | otherwise =
        case drop position values of
            value : _ -> Just value
            []        -> Nothing

inFrameBounds :: [a] -> Int -> Bool
inFrameBounds frame position =
    position >= 0 && position < length frame

inArgumentBounds :: [a] -> Int -> Bool
inArgumentBounds frame position =
    position >= 1 && position < length frame

isDecimalDigit :: Word8 -> Bool
isDecimalDigit byte =
    byte >= 48 && byte <= 57

asciiCaseEqual :: ByteString -> ByteString -> Bool
asciiCaseEqual left right =
    asciiUpper left == asciiUpper right

asciiUpper :: ByteString -> ByteString
asciiUpper =
    BS.map asciiToUpper

asciiToUpper :: Word8 -> Word8
asciiToUpper byte
    | byte >= 97 && byte <= 122 = byte - 32
    | otherwise = byte

renderCommandGrammarError :: CommandGrammarError -> String
renderCommandGrammarError errorValue =
    case errorValue of
        EmptyCommandFrame -> "empty command frame"
        UnknownCommand _ -> "unknown command"
        UnknownSubcommand command _ ->
            "unknown subcommand for " ++ BS8.unpack command
        InvalidArity command expected actual ->
            BS8.unpack command
                ++ " has invalid arity: expected "
                ++ show expected
                ++ " argument(s), got "
                ++ show actual
        MissingRequiredKeyword command keyword ->
            BS8.unpack command ++ " requires " ++ BS8.unpack keyword
        InvalidArguments command ->
            BS8.unpack command ++ " has malformed arguments"
        InvalidKeySpec command ->
            BS8.unpack command ++ " has malformed key arguments"
        InvalidKeyCount command ->
            BS8.unpack command ++ " has an invalid key count"
        UnsupportedKeySpec command ->
            BS8.unpack command ++ " uses an unsupported dynamic key specification"
