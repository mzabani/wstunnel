{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module WsTunnel.Slave (
    connectToMaster
  , MonadWsSlaveTunnel(..)
  , WsSlaveT
  ) where

import Data.Word
import qualified WsTunnel.Internal as Wsi
import Network.WebSockets hiding (receive)
import qualified Network.Connection as Network
import qualified Network.WebSockets as Ws
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Concurrent.STM
import Control.Concurrent.Async
import Data.String.Conv
import Data.Maybe
import Data.Monoid
import Control.Concurrent
import Control.Exception.Safe hiding (throwM, MonadThrow, catch, MonadCatch)
import Control.Monad.Catch (throwM, MonadThrow, MonadCatch, catch)
import Control.Monad.Reader
import Control.Monad.Trans
import Control.Monad.Base
import Control.Monad.Trans.Control
import qualified Data.Set as Set
import qualified Data.ByteString as Bs
import qualified Data.ByteString.Lazy as Lbs

-- | A monad transformer that enables methods to send and receive data to/from Master and to do other things as well
newtype WsSlaveT m a = WsSlaveT (Wsi.TunnelT m a)

class MonadWsSlaveTunnel m where
    -- | Sends some data to Master
    sendUnchanneledData :: Lbs.ByteString -> m ()
    -- | Receives some data from Master
    recvUnchanneledData :: m Lbs.ByteString
    -- | Block until all connections opened by Master are closed (either by Master or by the other parties).
    waitForAllConnections :: m ()
    getTunnel :: m Wsi.Tunnel

instance (MonadThrow m, MonadIO m) => MonadWsSlaveTunnel (WsSlaveT m) where
    sendUnchanneledData bs = WsSlaveT $ Wsi.sendUnchanneledData bs
    recvUnchanneledData = WsSlaveT Wsi.recvUnchanneledData
    waitForAllConnections = WsSlaveT Wsi.waitForAllConnections
    getTunnel = WsSlaveT Wsi.getTunnel

instance Functor m => Functor (WsSlaveT m) where
    fmap f (WsSlaveT v) = WsSlaveT $ fmap f v

instance (MonadIO m, Applicative m) => Applicative (WsSlaveT m) where
    (WsSlaveT f) <*> (WsSlaveT v) = WsSlaveT $ f <*> v
    pure = WsSlaveT . pure

instance (MonadIO m, Monad m) => Monad (WsSlaveT m) where
    return = pure
    (WsSlaveT wst) >>= f = WsSlaveT $ do
        v <- wst
        let (WsSlaveT x) = f v in x

instance MonadIO m => MonadIO (WsSlaveT m) where
    liftIO = WsSlaveT . liftIO

instance (MonadIO m, MonadThrow m) => MonadThrow (WsSlaveT m) where
    throwM = lift . throwM

instance (MonadIO m, MonadCatch m) => MonadCatch (WsSlaveT m) where
    catch (WsSlaveT action) handle = WsSlaveT $ catch action (\e -> let WsSlaveT vt = handle e in vt)

instance (MonadIO m, MonadBase b m) => MonadBase b (WsSlaveT m) where
  liftBase = liftBaseDefault

instance MonadTransControl WsSlaveT where
  type StT WsSlaveT a = StT Wsi.TunnelT a
  liftWith = defaultLiftWith WsSlaveT (\(WsSlaveT x) -> x)
  restoreT = defaultRestoreT WsSlaveT

instance (MonadIO m, MonadBaseControl b m) => MonadBaseControl b (WsSlaveT m) where
  type StM (WsSlaveT m) a = ComposeSt WsSlaveT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

instance MonadTrans WsSlaveT where
  lift = WsSlaveT . lift

instance (MonadIO m, MonadReader r m) => MonadReader r (WsSlaveT m) where
  ask = WsSlaveT $ lift ask
  local modf (WsSlaveT (Wsi.TunnelT rm)) = WsSlaveT . Wsi.TunnelT $ mapReaderT (local modf) rm

-- | Connects to a Master and start acting as a Slave. This means that connections can be opened
-- by this device as per Master's request. Bidirectional communication between this device and its Master
-- are also possible.
connectToMaster :: String -- ^ The Master's address 
                -> Int -- ^ The port on which the Master is listening
                -> String -- ^ The path ("/some/path" on "ws://masteraddress/some/path")
                -> WsSlaveT IO a -- ^ The code which will run after connecting to Master
                -> IO a
connectToMaster host port path (WsSlaveT tunnelTAction) = runClient host port path clientApp
      where clientApp conn = Wsi.runTunnelT finalAction conn
            processRec tunnel = catchAny (processConnectionRequest' tunnel) (const (return ())) >> processRec tunnel
            finalAction = do
                tunnel <- Wsi.getTunnel
                Wsi.forkAndForget (processRec tunnel)
                tunnelTAction

warnConnectionClosed :: Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
warnConnectionClosed tc@(Wsi.TunnelConnection code) tunnel = do
  Wsi.sendOp' (Wsi.SocketClosed code) tunnel
  Wsi.removeConnection' tc tunnel

-- | Waits for the master to open a connection to some host. Returns when it is opened and guarantees
-- that the tunnel continues until either side decides to close the connection
processConnectionRequest' :: Wsi.Tunnel -> IO ()
processConnectionRequest' tunnel@(Wsi.Tunnel wsconn tvars) = do
  connCtx <- Network.initConnectionContext
  (addr, port) <- Wsi.recvUntil' isOpenConnection tunnel
  let connParams = Network.ConnectionParams {
        Network.connectionHostname = toS addr,
        Network.connectionPort = fromIntegral port,
        Network.connectionUseSecure = Nothing,
        Network.connectionUseSocks = Nothing
    }
  Wsi.forkAndForget $ bracket (Network.connectTo connCtx connParams) Network.connectionClose $ \sock -> do
    connCode <- atomically $ do
        (connSet, msgQueue, lastCode) <- readTVar tvars
        writeTVar tvars (connSet, msgQueue, lastCode + 1)
        return (lastCode + 1)
    let tunConn = Wsi.TunnelConnection connCode
    bracket_ (Wsi.addConnection' tunConn tunnel) (Wsi.closeConnection' tunConn tunnel) $
        bracket_ (Wsi.sendOp' (Wsi.ConnectionOpened connCode) tunnel) (warnConnectionClosed tunConn tunnel) $
            withAsync (readFromSocketAndSendToTunnel sock tunConn tunnel) $ \as1 ->
                withAsync (readFromTunnelAndSendToSocket sock tunConn tunnel) $ \as2 ->
                    let recvSocketClosed op = case op of
                                                Wsi.SocketClosed connCode -> Just (Nothing, ())
                                                _                         -> Nothing
                    in withAsync (Wsi.recvUntil' recvSocketClosed tunnel) $ \as3 -> do
                         -- If any of the threads fail at any point or complete, resources must be released
                         waitAny [as1, as2, as3]
    where isOpenConnection op = case op of
                                    Wsi.OpenConnection addr port -> Just (Nothing, (addr, port))
                                    _                            -> Nothing

readFromSocketAndSendToTunnel :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromSocketAndSendToTunnel sock tc tref = do
    bs <- Network.connectionGetChunk sock
    if Bs.null bs
    then warnConnectionClosed tc tref
    else Wsi.sendData' (toS bs) tc tref >> readFromSocketAndSendToTunnel sock tc tref

readFromTunnelAndSendToSocket :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromTunnelAndSendToSocket sock tc tref = do
    bs <- Wsi.recvDataFrom' tc tref
    case bs of
      Wsi.BytesOnly _ bs           -> Network.connectionPut sock (toS bs) >> readFromTunnelAndSendToSocket sock tc tref
      Wsi.TunnelConnectionClosed _ -> Network.connectionClose sock >> warnConnectionClosed tc tref