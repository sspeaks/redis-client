{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module ClusterTunnel
  ( serveSmartProxy
  , servePinnedProxy
  , servePinnedProxyWith
  , SmartProxyFrameResult (..)
  , smartProxyFrameLimit
  , parseSmartProxyFrames
  , PinnedProxyLogMode (..)
  , PinnedProxyLogEntry (..)
  , emitPinnedProxyTrafficLog
  , PinnedRequest (..)
  , PinnedRequestScanner
  , initialPinnedRequestScanner
  , scanPinnedRequests
  , PinnedResponseResult (..)
  , pinnedResponseFrameLimit
  , parsePinnedResponses
  , parsePinnedResponsesWithLimit
  ) where

import           Control.Concurrent               (MVar, forkIO, newEmptyMVar,
                                                   putMVar, takeMVar)
import           Control.Concurrent.Async         (cancel, waitCatch,
                                                   waitEitherCatch, withAsync)
import           Control.Exception                (SomeException, bracket,
                                                   finally, throwIO, try)
import           Control.Monad                    (forever, replicateM_, void,
                                                   when)
import qualified Data.Attoparsec.ByteString       as StrictParse
import qualified Data.Attoparsec.ByteString.Char8 as Char8
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Builder          as Builder
import qualified Data.ByteString.Char8            as BS8
import qualified Data.ByteString.Lazy             as LBS
import           Data.Char                        (toUpper)
import           Data.Foldable                    (toList)
import           Data.IORef                       (IORef, atomicModifyIORef',
                                                   newIORef, readIORef)
import           Data.List                        (intercalate)
import qualified Data.Map.Strict                  as Map
import           Data.Sequence                    ((|>))
import qualified Data.Sequence                    as Seq
import           Database.Redis.Client            (Client (..),
                                                   ConnectionStatus (..))
import           Database.Redis.Cluster           (NodeAddress (..))
import           Database.Redis.Cluster.Client    (ClusterClient,
                                                   RedirectionInfo (..),
                                                   clusterMasterAddresses,
                                                   connectClusterNode,
                                                   forwardClusterFrame,
                                                   parseRedirectionError)
import           Database.Redis.Resp              (Encodable (encode),
                                                   RespData (..))
import qualified Database.Redis.Resp              as Resp
import           Network.Socket                   (Family (..), SockAddr (..),
                                                   Socket, SocketOption (..),
                                                   SocketType (..), bind,
                                                   defaultProtocol, listen,
                                                   setSocketOption, socket,
                                                   tupleToHostAddress)
import qualified Network.Socket                   as S
import           Network.Socket.ByteString        (recv, sendAll)
import           System.IO                        (BufferMode (LineBuffering),
                                                   hFlush, hSetBuffering,
                                                   stdout)
import           System.Timeout                   (timeout)
import           Text.Printf                      (printf)

data PinnedProxyLogMode
  = PinnedProxyLifecycleOnly
  | PinnedProxyVerboseTraffic
  deriving (Eq, Show)

data PinnedProxyLogEntry = PinnedProxyLogEntry
  { pinnedProxyLogMessage :: String
  , pinnedProxyLogFlush   :: Bool
  }
  deriving (Eq, Show)

type PinnedProxyLogSink = PinnedProxyLogEntry -> IO ()

data PinnedProxyTransferStats = PinnedProxyTransferStats
  { pinnedProxyClientChunks :: !Int
  , pinnedProxyClientBytes  :: !Int
  , pinnedProxyRedisChunks  :: !Int
  , pinnedProxyRedisBytes   :: !Int
  }
  deriving (Eq, Show)

emptyPinnedProxyTransferStats :: PinnedProxyTransferStats
emptyPinnedProxyTransferStats =
  PinnedProxyTransferStats
    { pinnedProxyClientChunks = 0
    , pinnedProxyClientBytes = 0
    , pinnedProxyRedisChunks = 0
    , pinnedProxyRedisBytes = 0
    }

stdoutPinnedProxyLogSink :: PinnedProxyLogSink
stdoutPinnedProxyLogSink entry = do
  putStrLn (pinnedProxyLogMessage entry)
  when (pinnedProxyLogFlush entry) $
    hFlush stdout

emitPinnedProxyLog :: PinnedProxyLogSink -> Bool -> String -> IO ()
emitPinnedProxyLog sink shouldFlush message =
  sink
    PinnedProxyLogEntry
      { pinnedProxyLogMessage = message
      , pinnedProxyLogFlush = shouldFlush
      }

emitPinnedProxyTrafficLog ::
  PinnedProxyLogMode ->
  PinnedProxyLogSink ->
  NodeAddress ->
  String ->
  BS.ByteString ->
  IO ()
emitPinnedProxyTrafficLog logMode sink addr direction payload =
  case logMode of
    PinnedProxyLifecycleOnly -> pure ()
    PinnedProxyVerboseTraffic ->
      emitPinnedProxyLog sink False $
        printf "[Pinned %s:%d] %s %d bytes preview=%s"
          (nodeHost addr)
          (nodePort addr)
          direction
          (BS.length payload)
          (renderPinnedProxyPayloadPreview payload)

renderPinnedProxyPayloadPreview :: BS.ByteString -> String
renderPinnedProxyPayloadPreview payload =
  let previewLimit = 96
      preview = show (BS.take previewLimit payload)
  in if BS.length payload > previewLimit
       then preview ++ "..."
       else preview

recordPinnedProxyClientChunk ::
  IORef PinnedProxyTransferStats ->
  BS.ByteString ->
  IO ()
recordPinnedProxyClientChunk statsRef payload =
  atomicModifyIORef' statsRef $ \stats ->
    ( stats
        { pinnedProxyClientChunks = pinnedProxyClientChunks stats + 1
        , pinnedProxyClientBytes = pinnedProxyClientBytes stats + BS.length payload
        }
    , ()
    )

recordPinnedProxyRedisChunk ::
  IORef PinnedProxyTransferStats ->
  BS.ByteString ->
  IO ()
recordPinnedProxyRedisChunk statsRef payload =
  atomicModifyIORef' statsRef $ \stats ->
    ( stats
        { pinnedProxyRedisChunks = pinnedProxyRedisChunks stats + 1
        , pinnedProxyRedisBytes = pinnedProxyRedisBytes stats + BS.length payload
        }
    , ()
    )

formatPinnedProxyTransferStats :: PinnedProxyTransferStats -> String
formatPinnedProxyTransferStats stats =
  printf
    "client=%d chunks/%d bytes redis=%d chunks/%d bytes"
    (pinnedProxyClientChunks stats)
    (pinnedProxyClientBytes stats)
    (pinnedProxyRedisChunks stats)
    (pinnedProxyRedisBytes stats)

-- | Smart proxy mode: Makes cluster appear as single Redis instance
-- Creates single listening socket and routes commands to appropriate nodes
serveSmartProxy :: (Client client) =>
  ClusterClient client ->
  IO ()
serveSmartProxy clusterClient = do
  hSetBuffering stdout LineBuffering
  bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
    setSocketOption sock ReuseAddr 1
    bind sock (SockAddrInet 6379 (tupleToHostAddress (127, 0, 0, 1)))
    listen sock 1024
    putStrLn "Smart proxy listening on localhost:6379"
    putStrLn "Cluster will appear as single Redis instance to clients"
    hFlush stdout

    -- Accept connections in a loop
    forever $ do
      (clientSock, clientAddr) <- S.accept sock
      printf "Accepted connection from %s\n" (show clientAddr)
      hFlush stdout

      -- Handle each client in a separate thread
      void $ forkIO $
        finally
          (handleSmartProxyClient clusterClient clientSock)
          (S.close clientSock)

-- | Handle a single client connection in smart proxy mode
handleSmartProxyClient :: (Client client) =>
  ClusterClient client ->
  Socket ->
  IO ()
handleSmartProxyClient clusterClient clientSock = do
  loop BS.empty
  where
    loop remainder = do
      -- Receive data from client
      dat <- recv clientSock 4096
      if BS.null dat
        then do
          when (not $ BS.null remainder) $
            putStrLn "Client disconnected with incomplete RESP command"
          putStrLn "Client disconnected"
        else
          case parseSmartProxyFrames remainder dat of
            SmartProxyFrames commands nextRemainder -> do
              mapM_ executeCommand commands
              loop nextRemainder
            SmartProxyFrameError commands err -> do
              mapM_ executeCommand commands
              printf "Failed to parse RESP: %s\n" err
              sendError $ "ERR Failed to parse command: " ++ err

    executeCommand respData =
      forwardClusterFrame clusterClient respData >>= sendResponse

    sendError message =
      sendResponse $ RespError (BS8.pack message)

    sendResponse response =
      sendAll clientSock (LBS.toStrict $ Builder.toLazyByteString $ encode response)

-- | Maximum number of bytes in one client request frame.  This bounds retained
-- TCP stream state independently of the fixed-size socket reads.
smartProxyFrameLimit :: Int
smartProxyFrameLimit = 1024 * 1024

-- | Results from draining all complete RESP request frames in a TCP chunk.
-- On failure, the preceding complete frames remain available to preserve stream
-- ordering, while the caller must terminate the connection without using bytes
-- after the invalid frame.
data SmartProxyFrameResult
  = SmartProxyFrames ![RespData] !BS.ByteString
  | SmartProxyFrameError ![RespData] !String
  deriving (Eq, Show)

-- | Append a TCP chunk to the pending request bytes and extract every complete
-- RESP frame.  The incomplete suffix is retained for the next socket read.
parseSmartProxyFrames ::
  BS.ByteString ->
  BS.ByteString ->
  SmartProxyFrameResult
parseSmartProxyFrames pending chunk = drain [] (pending <> chunk)
  where
    drain frames input =
      case BS.uncons input of
        Just (prefix, _)
          | prefix `notElem` validRespPrefixes ->
              SmartProxyFrameError
                (reverse frames)
                "invalid RESP frame: unknown data type prefix"
        _ -> case StrictParse.parse Resp.parseRespData input of
          StrictParse.Done remaining frame
            | BS.length input - BS.length remaining > smartProxyFrameLimit ->
                SmartProxyFrameError
                  (reverse frames)
                  "request frame exceeds 1048576 byte limit"
            | otherwise -> drain (frame : frames) remaining
          StrictParse.Partial _
            | BS.length input > smartProxyFrameLimit ->
                SmartProxyFrameError
                  (reverse frames)
                  "request frame exceeds 1048576 byte limit"
            | otherwise -> SmartProxyFrames (reverse frames) input
          StrictParse.Fail _ contexts message ->
              SmartProxyFrameError
                (reverse frames)
                ("invalid RESP frame: " ++ intercalate ", " contexts ++ ": " ++ message)

    validRespPrefixes = [43, 45, 58, 36, 42, 126, 37]

-- | Pinned proxy mode: One listener per cluster node
-- Each listener forwards to its corresponding cluster node
servePinnedProxy :: (Client client) =>
  ClusterClient client ->
  IO ()
servePinnedProxy = servePinnedProxyWith PinnedProxyLifecycleOnly

servePinnedProxyWith :: (Client client) =>
  PinnedProxyLogMode ->
  ClusterClient client ->
  IO ()
servePinnedProxyWith logMode clusterClient = do
  hSetBuffering stdout LineBuffering

  masters <- clusterMasterAddresses clusterClient

  when (null masters) $ do
    putStrLn "ERROR: No master nodes found in cluster topology"
    throwIO (userError "No master nodes in cluster")

  emitPinnedProxyLog
    stdoutPinnedProxyLogSink
    True
    (printf "Pinned proxy mode: Creating %d listeners for cluster nodes" (length masters))

  -- Create a listener for each master node
  mvars <- mapM (createPinnedListener logMode stdoutPinnedProxyLogSink clusterClient) masters

  emitPinnedProxyLog
    stdoutPinnedProxyLogSink
    True
    "All pinned listeners started. Press Ctrl+C to stop."

  -- Wait for all threads to complete (they won't unless there's an error)
  mapM_ takeMVar mvars

-- | Create a listener for a specific cluster node
createPinnedListener :: (Client client) =>
  PinnedProxyLogMode ->
  PinnedProxyLogSink ->
  ClusterClient client ->
  NodeAddress ->
  IO (MVar ())
createPinnedListener logMode logSink clusterClient addr = do
  mvar <- newEmptyMVar
  let localPort = nodePort addr

  void $ forkIO $ do
    result <- try $ bracket (socket AF_INET Stream defaultProtocol) S.close $ \sock -> do
      setSocketOption sock ReuseAddr 1
      bind sock (SockAddrInet (fromIntegral localPort) (tupleToHostAddress (127, 0, 0, 1)))
      listen sock 1024
      emitPinnedProxyLog
        logSink
        True
        (printf "Pinned listener on localhost:%d -> %s:%d"
          localPort (nodeHost addr) (nodePort addr))

      -- Accept connections for this node
      forever $ do
        (clientSock, clientAddr) <- S.accept sock
        emitPinnedProxyLog
          logSink
          True
          (printf "[Port %d] Accepted connection from %s" localPort (show clientAddr))

        -- Create dedicated connection for this pinned listener
        -- This is intentionally NOT using the connection pool because:
        -- 1. Pinned listeners maintain long-lived, persistent connections
        -- 2. Each listener needs its own connection tied to its lifecycle
        -- 3. Connection lifetime matches listener lifetime (closed when listener stops)
        redisConn <- connectClusterNode clusterClient addr
        statsRef <- newIORef emptyPinnedProxyTransferStats

        -- Handle forwarding in a separate thread
        void $ forkIO $ do
          result <- try $ forwardPinnedConnection logMode logSink statsRef clientSock redisConn addr
          stats <- readIORef statsRef
          case result of
            Left (e :: SomeException) -> do
              emitPinnedProxyLog
                logSink
                True
                (printf "[Port %d] Forwarding error: %s (%s)"
                  localPort
                  (show e)
                  (formatPinnedProxyTransferStats stats))
            Right _ -> do
              emitPinnedProxyLog
                logSink
                True
                (printf "[Port %d] Forwarding completed normally (%s)"
                  localPort
                  (formatPinnedProxyTransferStats stats))
          finally
            (do
              S.close clientSock
              close redisConn)
            (return ())

    case result of
      Left (e :: SomeException) -> do
        emitPinnedProxyLog
          logSink
          True
          (printf "Pinned listener on port %d failed: %s" localPort (show e))
        putMVar mvar ()
      Right _ -> putMVar mvar ()

  return mvar

-- | Forward traffic bidirectionally between client and cluster node.
-- Client bytes are forwarded unchanged; a copy is scanned to learn which
-- request each reply answers, so only topology replies and MOVED/ASK errors
-- are rewritten.  Completed replies are rewritten independently of TCP or TLS
-- chunking.
forwardPinnedConnection :: (Client client) =>
  PinnedProxyLogMode ->
  PinnedProxyLogSink ->
  IORef PinnedProxyTransferStats ->
  Socket ->
  client 'Connected ->
  NodeAddress ->
  IO ()
forwardPinnedConnection logMode logSink statsRef clientSock redisConn addr = do
  emitPinnedProxyLog
    logSink
    True
    (printf "[Pinned %s:%d] Starting forwarding loop" (nodeHost addr) (nodePort addr))
  expectedReplies <- newIORef Seq.empty
  withAsync (copyClientToRedis expectedReplies (Just initialPinnedRequestScanner)) $ \toRedis ->
    withAsync (copyRedisToClient expectedReplies BS.empty) $ \toClient -> do
      result <- waitEitherCatch toRedis toClient
      case result of
        Left (Left err)  -> cancel toClient >> throwIO err
        Right (Left err) -> cancel toRedis >> throwIO err
        Left (Right ())  -> do
          -- Redis connections are persistent, so an upstream EOF cannot mark
          -- the last reply.  Drain briefly after client write-side EOF, then
          -- cancel the blocked reader to bound connection/task lifetime.
          drained <- timeout halfCloseDrainMicros (waitCatch toClient)
          case drained of
            Just (Left err) -> throwIO err
            _               -> cancel toClient
        Right (Right ()) -> cancel toRedis
  where
    copyClientToRedis expectedReplies scanner = do
      dat <- recv clientSock 4096
      if BS.null dat
        then pure ()
        else do
          recordPinnedProxyClientChunk statsRef dat
          emitPinnedProxyTrafficLog logMode logSink addr "client->redis" dat
          -- Requests are queued before their bytes reach Redis, so a reply
          -- can never be read before the request it answers is known.
          nextScanner <- case scanner of
            Nothing -> pure Nothing
            Just current -> do
              let (requests, continued) = scanPinnedRequests current dat
              atomicModifyIORef' expectedReplies $ \queue ->
                (foldl (|>) queue requests, ())
              pure continued
          send redisConn (LBS.fromStrict dat)
          copyClientToRedis expectedReplies nextScanner

    copyRedisToClient expectedReplies pending = do
      response <- receive redisConn
      if BS.null response
        then pure ()
        else do
          recordPinnedProxyRedisChunk statsRef response
          emitPinnedProxyTrafficLog logMode logSink addr "redis->client" response
          queued <- readIORef expectedReplies
          let (result, answered) = parsePinnedResponses (toList queued) pending response
          -- Only this thread removes entries, so dropping the answered prefix
          -- is safe while the client thread appends.
          atomicModifyIORef' expectedReplies $ \queue -> (Seq.drop answered queue, ())
          case result of
            PinnedResponses output nextPending -> do
              sendAll clientSock output
              copyRedisToClient expectedReplies nextPending
            PinnedResponseLimitExceeded output -> do
              sendAll clientSock output
              throwIO $ userError "pinned response exceeds 512 MiB compatibility limit"
            PinnedResponseMalformed output -> do
              sendAll clientSock output
              throwIO $ userError "pinned response contains malformed streamed RESP3 framing"

halfCloseDrainMicros :: Int
halfCloseDrainMicros = 100000

-- | Maximum bulk payload accepted while awaiting an incomplete pinned response.
-- RESP framing bytes are allowed in addition to this Redis payload limit.
pinnedResponseFrameLimit :: Int
pinnedResponseFrameLimit = 512 * 1024 * 1024

data PinnedResponseResult
  = PinnedResponses !BS.ByteString !BS.ByteString
  | PinnedResponseLimitExceeded !BS.ByteString
  | PinnedResponseMalformed !BS.ByteString
  deriving (Eq, Show)

-- | Drain complete response frames.  Each reply is matched with the request
-- it answers, taken in order from the given expected replies; the second
-- result is how many of them were answered.  Only replies to CLUSTER SLOTS,
-- NODES and SHARDS and MOVED/ASK errors are rewritten; every other frame,
-- including RESP3 pushes and opaque RESP3 values, is forwarded byte-for-byte.
-- A malformed streamed value terminates the connection rather than allowing
-- line resynchronization to reinterpret bytes that might be chunk payload.
parsePinnedResponses ::
  [PinnedRequest] ->
  BS.ByteString ->
  BS.ByteString ->
  (PinnedResponseResult, Int)
parsePinnedResponses = parsePinnedResponsesWithLimit pinnedResponseFrameLimit

-- | Variant with an injected payload limit for boundary tests.
parsePinnedResponsesWithLimit ::
  Int ->
  [PinnedRequest] ->
  BS.ByteString ->
  BS.ByteString ->
  (PinnedResponseResult, Int)
parsePinnedResponsesWithLimit payloadLimit expected pending chunk =
  drain 0 expected BS.empty (pending <> chunk)
  where
    drain answered requests output input =
      case BS.uncons input of
        Just (prefix, _)
          | prefix `notElem` responseParserPrefixes ->
              drainOpaque answered requests output input
        _ -> case StrictParse.parse Resp.parseRespData input of
          StrictParse.Done remaining reply ->
            let consumed = BS.length input - BS.length remaining
                original = BS.take consumed input
                (request, laterRequests, nextAnswered) = answer answered requests
             in drain nextAnswered laterRequests
                  (output <> rewritePinnedReply request original reply)
                  remaining
          StrictParse.Partial _
            | responseExceedsLimit payloadLimit input ->
                (PinnedResponseLimitExceeded output, answered)
            | otherwise -> (PinnedResponses output input, answered)
          StrictParse.Fail {} -> drainOpaque answered requests output input

    drainOpaque answered requests output input =
      case StrictParse.parse opaqueResp3Frame input of
        StrictParse.Done remaining _ ->
          let consumed = BS.length input - BS.length remaining
              (_, laterRequests, nextAnswered)
                | BS.take 1 input == ">" = (PinnedOtherRequest, requests, answered)
                | otherwise = answer answered requests
           in drain nextAnswered laterRequests (output <> BS.take consumed input) remaining
        StrictParse.Partial _
          | responseExceedsLimit payloadLimit input ->
              (PinnedResponseLimitExceeded output, answered)
          | otherwise -> (PinnedResponses output input, answered)
        StrictParse.Fail {} ->
          if isStreamedResp3Start input
            then (PinnedResponseMalformed output, answered)
            else case BS.elemIndex 10 input of
          Just newline ->
            let consumed = newline + 1
             in drain answered requests (output <> BS.take consumed input) (BS.drop consumed input)
          Nothing
            | responseExceedsLimit payloadLimit input ->
                (PinnedResponseLimitExceeded output, answered)
            | otherwise -> (PinnedResponses output input, answered)

    -- A reply with no queued request (a RESP2 Pub/Sub message, or anything
    -- after tracking stopped) is never treated as a topology reply.
    answer answered requests =
      case requests of
        request : laterRequests -> (request, laterRequests, answered + 1)
        []                      -> (PinnedOtherRequest, [], answered)

    responseParserPrefixes = [43, 45, 58, 36, 42, 126, 37]

isStreamedResp3Start :: BS.ByteString -> Bool
isStreamedResp3Start input =
  BS.length input >= 4
    && BS.index input 0 `elem` [36, 33, 61, 42, 126, 62, 37, 124]
    && BS.take 3 (BS.drop 1 input) == "?\r\n"

-- | The extra wire budget is the largest legal top-level bulk header plus its
-- terminator.  This keeps the retained bound finite while accepting a maximum
-- Redis payload whose final CRLF arrives in a later read.
responseExceedsLimit :: Int -> BS.ByteString -> Bool
responseExceedsLimit payloadLimit input =
  payloadLimit < 0
    || maybe False (> toInteger payloadLimit) (declaredTopLevelBulkLength input)
    || BS.length input > payloadLimit + length (show payloadLimit) + 5

-- | A complete top-level bulk header lets us reject an oversized declared
-- payload before buffering it.  'readInteger' avoids an overflowing wire value
-- being mistaken for a small 'Int'.
declaredTopLevelBulkLength :: BS.ByteString -> Maybe Integer
declaredTopLevelBulkLength input = do
  header <- BS.stripPrefix "$" input
  let (digits, terminator) = BS.breakSubstring "\r\n" header
  _ <- BS.stripPrefix "\r\n" terminator
  (payloadLength, trailing) <- BS8.readInteger digits
  if BS.null trailing && payloadLength >= 0
    then Just payloadLength
    else Nothing

-- | Parse a complete opaque RESP3 value without constructing a 'RespData'.
-- Pinned mode needs only a trustworthy frame boundary, including streamed
-- chunks and streamed aggregates, before it can inspect a later RESP2 frame.
opaqueResp3Frame :: StrictParse.Parser ()
opaqueResp3Frame = do
  prefix <- StrictParse.anyWord8
  case prefix of
    43  -> opaqueLine
    45  -> opaqueLine
    58  -> opaqueLine
    44  -> opaqueLine
    40  -> opaqueLine
    95  -> opaqueCRLF
    35  -> StrictParse.anyWord8 >> opaqueCRLF
    36  -> opaqueBulkOrStream
    33  -> opaqueBulkOrStream
    61  -> opaqueBulkOrStream
    42  -> opaqueAggregateOrStream 1
    126 -> opaqueAggregateOrStream 1
    62  -> opaqueAggregateOrStream 1
    37  -> opaqueAggregateOrStream 2
    124 -> opaqueAggregateOrStream 2
    _   -> fail "unknown RESP3 data type"
  where
    opaqueLine = StrictParse.takeTill (\c -> c == 13 || c == 10) >> opaqueCRLF
    opaqueCRLF = void (StrictParse.word8 13) >> void (StrictParse.word8 10)
    opaqueBulkOrStream = do
      marker <- StrictParse.peekWord8'
      if marker == 63 then opaqueStreamedBulk else opaqueBulk
    opaqueBulk = do
      size <- Char8.signed Char8.decimal
      opaqueCRLF
      if size == (-1)
        then pure ()
        else if size < 0
          then fail "invalid RESP bulk length"
          else StrictParse.take size >> opaqueCRLF
    opaqueStreamedBulk = StrictParse.word8 63 >> opaqueCRLF >> opaqueChunks
    opaqueChunks = do
      _ <- StrictParse.word8 59
      size <- Char8.decimal
      opaqueCRLF
      if size == 0
        then pure ()
        else if size < 0
          then fail "invalid RESP streamed chunk length"
          else StrictParse.take size >> opaqueCRLF >> opaqueChunks
    opaqueAggregateOrStream multiplier = do
      marker <- StrictParse.peekWord8'
      if marker == 63 then opaqueStreamedAggregate else opaqueAggregate multiplier
    opaqueAggregate multiplier = do
      count <- Char8.signed Char8.decimal
      opaqueCRLF
      if count == (-1)
        then pure ()
        else if count < 0
          then fail "invalid RESP aggregate length"
          else if count > maxBound `div` multiplier
            then fail "RESP aggregate length overflow"
            else replicateM_ (count * multiplier) opaqueResp3Frame
    opaqueStreamedAggregate = StrictParse.word8 63 >> opaqueCRLF >> opaqueStreamedValues
    opaqueStreamedValues = do
      marker <- StrictParse.peekWord8'
      if marker == 46
        then StrictParse.word8 46 >> opaqueCRLF
        else opaqueResp3Frame >> opaqueStreamedValues

-- | What the pinned proxy needs to know about one client request.
data PinnedRequest
  = PinnedClusterSlots
  | PinnedClusterNodes
  | PinnedClusterShards
  | PinnedOtherRequest
  | PinnedStopTracking
    -- ^ The request breaks the one-reply-per-request order (Pub/Sub, MONITOR,
    -- CLIENT REPLY) or could not be framed.  Later replies are not matched
    -- with requests, so none of them is treated as a topology reply.
  deriving (Eq, Show)

-- | Streaming scanner for client request frames.  It keeps only the first two
-- arguments of the current request, truncated, so large values are skipped
-- without being buffered.
data PinnedRequestScanner = PinnedRequestScanner
  { scannerPhase     :: !ScanPhase
  , scannerArgsLeft  :: !Int
  , scannerArguments :: ![BS.ByteString]
  }

data ScanPhase
  = AwaitArrayHeader !BS.ByteString
  | AwaitBulkHeader !BS.ByteString
  | InBulkPayload !Int !BS.ByteString

initialPinnedRequestScanner :: PinnedRequestScanner
initialPinnedRequestScanner = PinnedRequestScanner (AwaitArrayHeader BS.empty) 0 []

-- | Classify every request completed by a chunk of client bytes.  The scanner
-- is 'Nothing' once tracking has stopped; the last request is then
-- 'PinnedStopTracking'.  Inline commands and malformed frames stop tracking.
scanPinnedRequests ::
  PinnedRequestScanner ->
  BS.ByteString ->
  ([PinnedRequest], Maybe PinnedRequestScanner)
scanPinnedRequests initial = go [] initial
  where
    go requests scanner input
      | BS.null input = (reverse requests, Just scanner)
      | otherwise =
          case scannerPhase scanner of
            AwaitArrayHeader partial ->
              readHeader requests partial input (\line -> scanner { scannerPhase = AwaitArrayHeader line }) $
                \line rest -> case parseHeader '*' line of
                  Just count
                    | count <= 0 -> go requests (scanner { scannerPhase = AwaitArrayHeader BS.empty }) rest
                    | otherwise ->
                        go requests (PinnedRequestScanner (AwaitBulkHeader BS.empty) count []) rest
                  Nothing -> stop requests
            AwaitBulkHeader partial ->
              readHeader requests partial input (\line -> scanner { scannerPhase = AwaitBulkHeader line }) $
                \line rest -> case parseHeader '$' line of
                  Just size
                    | size >= 0 && size <= pinnedResponseFrameLimit ->
                        go requests (scanner { scannerPhase = InBulkPayload (size + 2) BS.empty }) rest
                  _ -> stop requests
            InBulkPayload remaining captured ->
              let (taken, rest) = BS.splitAt remaining input
                  stillNeeded = remaining - BS.length taken
                  captured'
                    | length (scannerArguments scanner) < 2 =
                        BS.take capturedArgumentLimit
                          (captured <> BS.take capturedArgumentLimit taken)
                    | otherwise = captured
               in if stillNeeded > 0
                    then go requests (scanner { scannerPhase = InBulkPayload stillNeeded captured' }) rest
                    else
                      let argument = BS.take (BS.length captured' - trailingCRLF captured') captured'
                          arguments = scannerArguments scanner ++ [argument | length (scannerArguments scanner) < 2]
                          argsLeft = scannerArgsLeft scanner - 1
                       in if argsLeft > 0
                            then go requests (PinnedRequestScanner (AwaitBulkHeader BS.empty) argsLeft arguments) rest
                            else
                              let request = classifyPinnedRequest arguments
                               in if request == PinnedStopTracking
                                    then (reverse (request : requests), Nothing)
                                    else go (request : requests) initialPinnedRequestScanner rest

    stop requests = (reverse (PinnedStopTracking : requests), Nothing)

    readHeader requests partial input waiting continue =
      case BS.elemIndex 10 input of
        Just newline ->
          continue (partial <> BS.take (newline + 1) input) (BS.drop (newline + 1) input)
        Nothing
          | BS.length partial + BS.length input > headerLimit -> stop requests
          | otherwise -> (reverse requests, Just (waiting (partial <> input)))

    -- An argument of up to 16 bytes is captured with its CRLF.  A longer one
    -- is truncated; it is never compared in full, so a coincidental trailing
    -- CRLF does not matter.
    trailingCRLF bytes
      | "\r\n" `BS.isSuffixOf` bytes = 2
      | otherwise = 0

    parseHeader marker line = do
      body <- BS.stripPrefix (BS8.singleton marker) line
      digits <- BS.stripSuffix "\r\n" body
      (value, trailing) <- BS8.readInt digits
      if BS.null trailing then Just value else Nothing

    headerLimit = 32
    capturedArgumentLimit = 18

classifyPinnedRequest :: [BS.ByteString] -> PinnedRequest
classifyPinnedRequest arguments =
  case map (BS8.map toUpper) arguments of
    ["CLUSTER", "SLOTS"]  -> PinnedClusterSlots
    ["CLUSTER", "NODES"]  -> PinnedClusterNodes
    ["CLUSTER", "SHARDS"] -> PinnedClusterShards
    ["CLIENT", "REPLY"]   -> PinnedStopTracking
    command : _
      | command `elem` orderBreakingCommands -> PinnedStopTracking
    _ -> PinnedOtherRequest
  where
    orderBreakingCommands =
      [ "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE"
      , "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE"
      , "MONITOR"
      ]

-- | Rewrite one complete reply for the request it answers.  Untouched replies
-- are returned as their original bytes.
rewritePinnedReply :: PinnedRequest -> BS.ByteString -> RespData -> BS.ByteString
rewritePinnedReply request original reply =
  case (request, reply) of
    (_, RespError message) ->
      maybe original (encodeReply . RespError) (rewriteRedirection message)
    (PinnedClusterSlots, RespArray ranges) ->
      encodeReply $ RespArray (map rewriteSlotRange ranges)
    (PinnedClusterNodes, RespBulkString text) ->
      encodeReply $ RespBulkString (rewriteClusterNodesText text)
    (PinnedClusterShards, _) ->
      encodeReply $ rewriteShardEndpoints reply
    _ -> original
  where
    encodeReply = LBS.toStrict . Builder.toLazyByteString . encode

-- | MOVED/ASK errors keep their slot and port, with the host replaced by the
-- local listener address.
rewriteRedirection :: BS.ByteString -> Maybe BS.ByteString
rewriteRedirection message =
  case (parseRedirectionError "MOVED" message, parseRedirectionError "ASK" message) of
    (Just redirection, _) -> Just $ redirect "MOVED" redirection
    (_, Just redirection) -> Just $ redirect "ASK" redirection
    _                     -> Nothing
  where
    redirect kind redirection =
      kind <> " " <> BS8.pack (show $ redirSlot redirection)
        <> " 127.0.0.1:" <> BS8.pack (show $ redirPort redirection)

-- | CLUSTER SLOTS: @[start, end, node, node...]@ where each node starts with
-- its endpoint.  An unknown endpoint (empty or @?@) is left as is.
rewriteSlotRange :: RespData -> RespData
rewriteSlotRange (RespArray (start : end : nodes)) =
  RespArray (start : end : map rewriteNode nodes)
  where
    rewriteNode (RespArray (RespBulkString endpoint : details))
      | knownEndpoint endpoint = RespArray (RespBulkString "127.0.0.1" : details)
    rewriteNode node = node
rewriteSlotRange other = other

-- | CLUSTER SHARDS: rewrite the values of endpoint fields in every key/value
-- list or map.
rewriteShardEndpoints :: RespData -> RespData
rewriteShardEndpoints reply =
  case reply of
    RespArray items -> RespArray (rewritePairs (map rewriteShardEndpoints items))
    RespMap fields ->
      RespMap $ Map.mapWithKey rewriteField (Map.map rewriteShardEndpoints fields)
    other -> other
  where
    rewritePairs (RespBulkString key : RespBulkString value : rest)
      | isEndpointField key && knownEndpoint value =
          RespBulkString key : RespBulkString "127.0.0.1" : rewritePairs rest
    rewritePairs (key : value : rest) = key : value : rewritePairs rest
    rewritePairs rest = rest

    rewriteField (RespBulkString key) (RespBulkString value)
      | isEndpointField key && knownEndpoint value = RespBulkString "127.0.0.1"
    rewriteField _ value = value

    isEndpointField key = key `elem` ["endpoint", "ip", "hostname"]

knownEndpoint :: BS.ByteString -> Bool
knownEndpoint endpoint = not (BS.null endpoint) && endpoint /= "?"

-- | Rewrite CLUSTER NODES response text
rewriteClusterNodesText :: BS.ByteString -> BS.ByteString
rewriteClusterNodesText bs =
  let text = BS8.unpack bs
      textLines = lines text
      rewritten = map rewriteClusterNodesLine textLines
  in BS8.pack (unlines rewritten)

-- | Rewrite a single line from CLUSTER NODES
rewriteClusterNodesLine :: String -> String
rewriteClusterNodesLine line =
  let parts = words line
  in case parts of
       (nodeId:hostPort:rest) ->
         case break (== ':') hostPort of
           (_, '@':_) ->
             -- Format: host:port@cport
             case break (== '@') hostPort of
               (hp, cport) ->
                 case break (== ':') hp of
                   (_, ':':port) ->
                     nodeId ++ " 127.0.0.1:" ++ port ++ cport ++ " " ++ unwords rest
                   _ -> line
           (_, ':':port) ->
             -- Format: host:port
             nodeId ++ " 127.0.0.1:" ++ port ++ " " ++ unwords rest
           _ -> line
       _ -> line

-- End of ClusterTunnel module
