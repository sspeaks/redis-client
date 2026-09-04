{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import           Control.Concurrent                    (forkFinally, forkIO,
                                                        killThread, threadDelay)
import           Control.Concurrent.MVar               (MVar, newEmptyMVar,
                                                        putMVar, takeMVar)
import           Control.Exception                     (SomeException)
import qualified Control.Exception                     as Exception
import           Control.Monad                         (forM, replicateM_)
import           Control.Monad.IO.Class                (liftIO)
import           Data.IORef                            (IORef,
                                                        atomicModifyIORef',
                                                        newIORef, readIORef)
import           Database.Redis.Client                 (Client (..),
                                                        ConnectionStatus (..))
import           Database.Redis.Cluster                (NodeAddress (..))
import           Database.Redis.Cluster.ConnectionPool
import           Database.Redis.Connector              (ConnectionPhase (..),
                                                        ConnectionSetupException (..))
import           GHC.Clock                             (getMonotonicTimeNSec)
import           System.Timeout                        (timeout)
import           Test.Hspec

data MockClient (a :: ConnectionStatus) where
  MockConnected :: !Int -> !(IORef Int) -> MockClient 'Connected

instance Client MockClient where
  connect = error "unused"
  close (MockConnected _ closeCount) =
    liftIO $ atomicModifyIORef' closeCount $ \count -> (count + 1, ())
  send _ _ = return ()
  receive _ = return mempty

data BlockingCloseClient (a :: ConnectionStatus) where
  BlockingCloseConnected
    :: !(MVar ())
    -> !(MVar ())
    -> !(MVar ())
    -> BlockingCloseClient 'Connected

instance Client BlockingCloseClient where
  connect = error "unused"
  close (BlockingCloseConnected started release finished) = liftIO $ do
    putMVar started ()
    takeMVar release
    putMVar finished ()
  send _ _ = return ()
  receive _ = return mempty

node :: NodeAddress
node = NodeAddress "127.0.0.1" 6379

testPoolConfig :: PoolConfig
testPoolConfig = PoolConfig
  { maxConnectionsPerNode = 1
  , connectionTimeout = 5
  , maxRetries = 0
  , useTLS = False
  }

createCountingConnector
  :: IO (NodeAddress -> IO (MockClient 'Connected), IORef Int, IORef Int)
createCountingConnector = do
  connectionCount <- newIORef 0
  closeCount <- newIORef 0
  let connector _ = do
        connectionId <- atomicModifyIORef' connectionCount $ \count ->
          let next = count + 1
          in (next, next)
        return $ MockConnected connectionId closeCount
  return (connector, connectionCount, closeCount)

forkResult :: IO a -> IO (MVar (Either SomeException a), IO ())
forkResult action = do
  result <- newEmptyMVar
  thread <- forkFinally action (putMVar result)
  return (result, killThread thread)

awaitWaiters :: ConnectionPool client -> Int -> IO ()
awaitWaiters pool expected = do
  stats <- getConnectionPoolStats pool node
  if statsWaitingCallers stats == expected
    then return ()
    else threadDelay 1000 >> awaitWaiters pool expected

awaitIORefValue :: IORef Int -> Int -> IO ()
awaitIORefValue ref expected = do
  actual <- readIORef ref
  if actual == expected
    then return ()
    else threadDelay 1000 >> awaitIORefValue ref expected

expectWithin :: IO a -> IO a
expectWithin action =
  timeout 2000000 action >>= \case
    Just result -> return result
    Nothing     -> do
      expectationFailure "operation did not complete within two seconds"
      fail "timeout"

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

main :: IO ()
main = hspec $ describe "ConnectionPool lifecycle" $ do
  it "recovers capacity when connector acquisition is cancelled" $ do
    pool <- createPool testPoolConfig
    connectionCount <- newIORef (0 :: Int)
    closeCount <- newIORef (0 :: Int)
    connectorStarted <- newEmptyMVar
    releaseConnector <- newEmptyMVar
    let connector _ = do
          attempt <- atomicModifyIORef' connectionCount $ \count ->
            let next = count + 1
            in (next, next)
          if attempt == 1
            then putMVar connectorStarted () >> takeMVar releaseConnector
            else return $ MockConnected attempt closeCount

    (firstResult, cancelFirst) <- forkResult $
      withConnection pool node connector $ \_ -> return ()
    expectWithin (takeMVar connectorStarted)
    cancelFirst
    firstOutcome <- expectWithin (takeMVar firstResult)
    firstOutcome `shouldSatisfy` either (const True) (const False)

    expectWithin (withConnection pool node connector $ \_ -> return ())
    readIORef connectionCount `shouldReturn` 2
    getConnectionPoolStats pool node
      `shouldReturn` ConnectionPoolStats 1 1 0
    closePool pool
    readIORef closeCount `shouldReturn` 1

  mapM_ (\(label, tlsEnabled, expectedPhase) ->
    it ("bounds stalled " <> label <> " setup and closes its allocated resource once") $ do
      attempts <- newIORef (0 :: Int)
      closeCount <- newIORef (0 :: Int)
      stalled <- newEmptyMVar
      let config = testPoolConfig
            { connectionTimeout = 1
            , useTLS = tlsEnabled
            }
          connector _ = do
            atomicModifyIORef' attempts $ \count -> (count + 1, ())
            _ <- Exception.onException
              (takeMVar stalled)
              (atomicModifyIORef' closeCount $ \count -> (count + 1, ()))
            return $ MockConnected 1 closeCount

      pool <- createPool config
      started <- getMonotonicTimeNSec
      result <- (Exception.try $
        withConnection pool node connector $ \_ -> return ())
        :: IO (Either SomeException ())
      finished <- getMonotonicTimeNSec
      let elapsedSeconds =
            fromIntegral (finished - started) / 1000000000 :: Double

      result `shouldSatisfy` \case
        Left err ->
          Exception.fromException err
            == Just (ConnectionSetupTimeout expectedPhase node 1)
        Right () -> False
      elapsedSeconds `shouldSatisfy` \elapsed ->
        elapsed >= 0.75 && elapsed < 3
      readIORef attempts `shouldReturn` 1
      expectWithin $ awaitIORefValue closeCount 1
      readIORef closeCount `shouldReturn` 1
      getConnectionPoolStats pool node
        `shouldReturn` ConnectionPoolStats 0 0 0
      closePool pool
      readIORef closeCount `shouldReturn` 1
    )
    [ ("plaintext TCP connect", False, PlaintextConnectionSetup)
    , ("TLS handshake", True, TLSConnectionSetup)
    ]

  it "removes cancelled saturated waiters before direct handoff" $ do
    pool <- createPool testPoolConfig
    (connector, connectionCount, closeCount) <- createCountingConnector
    holderStarted <- newEmptyMVar
    releaseHolder <- newEmptyMVar
    (holderResult, _) <- forkResult $
      withConnection pool node connector $ \_ ->
        putMVar holderStarted () >> takeMVar releaseHolder
    expectWithin (takeMVar holderStarted)

    (cancelledResult, cancelWaiterThread) <- forkResult $
      withConnection pool node connector $ \_ -> return ()
    expectWithin (awaitWaiters pool 1)
    cancelWaiterThread
    cancelledOutcome <- expectWithin (takeMVar cancelledResult)
    cancelledOutcome `shouldSatisfy` either (const True) (const False)
    expectWithin (awaitWaiters pool 0)

    (laterResult, _) <- forkResult $
      withConnection pool node connector $ \_ -> return ()
    expectWithin (awaitWaiters pool 1)
    putMVar releaseHolder ()
    holderOutcome <- expectWithin (takeMVar holderResult)
    holderOutcome `shouldSatisfy` isRight
    laterOutcome <- expectWithin (takeMVar laterResult)
    laterOutcome `shouldSatisfy` isRight

    readIORef connectionCount `shouldReturn` 1
    getConnectionPoolStats pool node
      `shouldReturn` ConnectionPoolStats 1 1 0
    closePool pool
    readIORef closeCount `shouldReturn` 1

  it "cannot lose a connection when cancellation waits behind return accounting" $ do
    pool <- createPool testPoolConfig
    (connector, connectionCount, closeCount) <- createCountingConnector
    actionStarted <- newEmptyMVar
    releaseAction <- newEmptyMVar
    (ownerResult, cancelOwner) <- forkResult $
      withConnection pool node connector $ \_ ->
        putMVar actionStarted () >> takeMVar releaseAction
    expectWithin (takeMVar actionStarted)

    state <- takeMVar (poolConnections pool)
    putMVar releaseAction ()
    threadDelay 10000
    cancellationFinished <- newEmptyMVar
    _ <- forkIO $ cancelOwner >> putMVar cancellationFinished ()
    putMVar (poolConnections pool) state
    expectWithin (takeMVar cancellationFinished)
    _ <- expectWithin (takeMVar ownerResult)

    expectWithin (withConnection pool node connector $ \_ -> return ())
    readIORef connectionCount `shouldReturn` 1
    getConnectionPoolStats pool node
      `shouldReturn` ConnectionPoolStats 1 1 0
    closePool pool
    readIORef closeCount `shouldReturn` 1

  it "recovers a direct handoff when the selected waiter is cancelled" $
    replicateM_ 25 $ do
      pool <- createPool testPoolConfig
      (connector, connectionCount, closeCount) <- createCountingConnector
      holderStarted <- newEmptyMVar
      releaseHolder <- newEmptyMVar
      (holderResult, _) <- forkResult $
        withConnection pool node connector $ \_ ->
          putMVar holderStarted () >> takeMVar releaseHolder
      expectWithin (takeMVar holderStarted)

      (waiterResult, cancelSelectedWaiter) <- forkResult $
        withConnection pool node connector $ \_ -> return ()
      expectWithin (awaitWaiters pool 1)

      state <- takeMVar (poolConnections pool)
      putMVar releaseHolder ()
      threadDelay 1000
      cancelSelectedWaiter
      putMVar (poolConnections pool) state

      holderOutcome <- expectWithin (takeMVar holderResult)
      holderOutcome `shouldSatisfy` isRight
      waiterOutcome <- expectWithin (takeMVar waiterResult)
      waiterOutcome `shouldSatisfy` either (const True) (const False)
      expectWithin (withConnection pool node connector $ \_ -> return ())

      readIORef connectionCount `shouldReturn` 1
      getConnectionPoolStats pool node
        `shouldReturn` ConnectionPoolStats 1 1 0
      closePool pool
      readIORef closeCount `shouldReturn` 1

  it "preserves cancellation while an independent transport close finishes" $ do
    pool <- createPool testPoolConfig
    actionStarted <- newEmptyMVar
    releaseAction <- newEmptyMVar
    closeStarted <- newEmptyMVar
    releaseClose <- newEmptyMVar
    closeFinished <- newEmptyMVar
    let connector _ =
          return $ BlockingCloseConnected closeStarted releaseClose closeFinished

    (ownerResult, cancelOwner) <- forkResult $
      withConnection pool node connector $ \_ ->
        putMVar actionStarted () >> takeMVar releaseAction
    expectWithin (takeMVar actionStarted)
    closePool pool
    putMVar releaseAction ()
    expectWithin (takeMVar closeStarted)
    cancelOwner
    ownerOutcome <- expectWithin (takeMVar ownerResult)
    ownerOutcome `shouldSatisfy` either (const True) (const False)
    putMVar releaseClose ()
    expectWithin (takeMVar closeFinished)

  it "preserves accounting after a saturated cancellation storm" $ do
    pool <- createPool testPoolConfig
    (connector, connectionCount, closeCount) <- createCountingConnector
    holderStarted <- newEmptyMVar
    releaseHolder <- newEmptyMVar
    (holderResult, _) <- forkResult $
      withConnection pool node connector $ \_ ->
        putMVar holderStarted () >> takeMVar releaseHolder
    expectWithin (takeMVar holderStarted)

    waiters <- forM [1 .. 64 :: Int] $ \_ ->
      forkResult $ withConnection pool node connector $ \_ -> return ()
    expectWithin (awaitWaiters pool 64)
    mapM_ snd (take 32 waiters)
    mapM_ (expectWithin . takeMVar . fst) (take 32 waiters)
    expectWithin (awaitWaiters pool 32)

    putMVar releaseHolder ()
    holderOutcome <- expectWithin (takeMVar holderResult)
    holderOutcome `shouldSatisfy` isRight
    mapM_ (\(result, _) -> do
      outcome <- expectWithin (takeMVar result)
      outcome `shouldSatisfy` isRight) (drop 32 waiters)

    replicateM_ 16 $
      expectWithin (withConnection pool node connector $ \_ -> return ())
    readIORef connectionCount `shouldReturn` 1
    getConnectionPoolStats pool node
      `shouldReturn` ConnectionPoolStats 1 1 0
    closePool pool
    readIORef closeCount `shouldReturn` 1
