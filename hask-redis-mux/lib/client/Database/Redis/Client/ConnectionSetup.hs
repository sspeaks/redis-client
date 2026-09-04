module Database.Redis.Client.ConnectionSetup
  ( ConnectionPhase (..)
  , PhaseSetter
  , CleanupRegistrar
  , PlaintextSetupOperations (..)
  , TLSSetupOperations (..)
  , runPlaintextSetup
  , runTLSSetup
  ) where

import           Control.Exception (finally, mask, onException)

-- | The production connection phase active when a setup deadline expires.
data ConnectionPhase
  = DNSResolution
  | SocketCreation
  | SocketConfiguration
  | TCPConnection
  | TLSContextCreation
  | TLSHandshake
  | Authentication
  | PlaintextConnectionSetup
  | TLSConnectionSetup
  deriving (Eq, Show)

type PhaseSetter = ConnectionPhase -> IO ()
type CleanupRegistrar = IO () -> IO (IO ())

data PlaintextSetupOperations socket address connected = PlaintextSetupOperations
  { plaintextResolve         :: IO address
  , plaintextOpenSocket      :: IO socket
  , plaintextConfigureSocket :: socket -> IO ()
  , plaintextConnectSocket   :: socket -> address -> IO ()
  , plaintextCloseSocket     :: socket -> IO ()
  , plaintextConnected       :: socket -> address -> IO () -> connected
  }

data TLSSetupOperations socket address store context connected = TLSSetupOperations
  { tlsResolve         :: IO address
  , tlsOpenSocket      :: IO socket
  , tlsConfigureSocket :: socket -> IO ()
  , tlsConnectSocket   :: socket -> address -> IO ()
  , tlsCloseSocket     :: socket -> IO ()
  , tlsLoadStore       :: IO store
  , tlsCreateContext   :: socket -> store -> IO context
  , tlsCloseContext    :: context -> IO ()
  , tlsRunHandshake    :: context -> IO ()
  , tlsConnected       :: socket -> address -> context -> IO () -> connected
  }

runPlaintextSetup
  :: PhaseSetter
  -> CleanupRegistrar
  -> PlaintextSetupOperations socket address connected
  -> IO connected
runPlaintextSetup setPhase registerCleanup operations =
  mask $ \restore -> do
    setPhase DNSResolution
    address <- restore $ plaintextResolve operations
    setPhase SocketCreation
    sock <- restore $ plaintextOpenSocket operations
    cleanup <- registerCleanup $ plaintextCloseSocket operations sock
    restore (do
      setPhase SocketConfiguration
      plaintextConfigureSocket operations sock
      setPhase TCPConnection
      plaintextConnectSocket operations sock address
      return $ plaintextConnected operations sock address cleanup)
      `onException` cleanup

runTLSSetup
  :: PhaseSetter
  -> CleanupRegistrar
  -> TLSSetupOperations socket address store context connected
  -> IO connected
runTLSSetup setPhase registerCleanup operations =
  mask $ \restore -> do
    setPhase DNSResolution
    address <- restore $ tlsResolve operations
    setPhase SocketCreation
    sock <- restore $ tlsOpenSocket operations
    socketCleanup <- registerCleanup $ tlsCloseSocket operations sock
    restore (do
      setPhase SocketConfiguration
      tlsConfigureSocket operations sock
      setPhase TCPConnection
      tlsConnectSocket operations sock address
      setPhase TLSContextCreation
      store <- tlsLoadStore operations
      context <- tlsCreateContext operations sock store
      contextCleanup <- registerCleanup $
        tlsCloseContext operations context `finally` socketCleanup
      (do
          setPhase TLSHandshake
          tlsRunHandshake operations context
          return $
            tlsConnected operations sock address context contextCleanup)
        `onException` contextCleanup)
      `onException` socketCleanup
