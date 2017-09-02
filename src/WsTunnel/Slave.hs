{-# LANGUAGE OverloadedStrings #-}
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
-- import Control.Monad.Catch
import Control.Concurrent.MVar
import Data.String.Conv
import Data.Maybe
import Data.Monoid
import Control.Concurrent
import Control.Exception.Safe
-- import Control.Monad.IO.Unlift
import qualified Data.Set as Set
import qualified Data.ByteString as Bs
import qualified Data.ByteString.Lazy as Lbs

newtype WsSlaveT m a = WsSlaveT (Wsi.TunnelT m a)

class MonadWsSlaveTunnel m where
    processConnectionRequest :: m ()
    sendUnchanneledData :: Lbs.ByteString -> m ()
    recvUnchanneledData :: m Lbs.ByteString
    waitForAllConnections :: m ()
    getTunnel :: m Wsi.Tunnel

instance (MonadThrow m, MonadIO m) => MonadWsSlaveTunnel (WsSlaveT m) where
    processConnectionRequest = processConnectionRequest'
    sendUnchanneledData bs = WsSlaveT $ Wsi.sendUnchanneledData bs
    recvUnchanneledData = WsSlaveT $ Wsi.recvUnchanneledData
    waitForAllConnections = WsSlaveT $ Wsi.waitForAllConnections
    getTunnel = WsSlaveT $ Wsi.getTunnel

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

connectToMaster :: String -> Int -> String -> WsSlaveT IO a -> IO a
connectToMaster host port path (WsSlaveT tunnelTAction) = runClient host port path clientApp
      where clientApp conn = Wsi.runTunnelT tunnelTAction conn

warnConnectionClosed :: Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
warnConnectionClosed (Wsi.TunnelConnection code) tunnel@(Wsi.Tunnel conn _ _) = do
  Prelude.putStrLn "Sending warnconnectionclosed"
  Wsi.sendOp' (Wsi.SocketClosed code) tunnel

-- ^ Waits for the master to open a connection to some host. Returns when it is opened and guarantees
--   that the tunnel continues until either side decides to close the connection
processConnectionRequest' :: (MonadIO m, MonadThrow m) => WsSlaveT m ()
processConnectionRequest' = WsSlaveT $ do
  tunnel@(Wsi.Tunnel wsconn mvars _) <- Wsi.getTunnel
  connCtx <- liftIO $ Network.initConnectionContext
  (addr, port) <- Wsi.recvUntil' isOpenConnection tunnel
  sock <- liftIO $ Network.connectTo connCtx Network.ConnectionParams {
      Network.connectionHostname = toS addr,
      Network.connectionPort = fromIntegral port,
      Network.connectionUseSecure = Nothing,
      Network.connectionUseSocks = Nothing
  }
  connCode <- liftIO $ modifyMVar mvars (\t@(connSet, msgQueue, lastCode) -> return $ ((connSet, msgQueue, lastCode + 1), lastCode + 1))
  Wsi.addConnection $ Wsi.TunnelConnection connCode
  Wsi.sendOp (Wsi.ConnectionOpened connCode)
  liftIO $ forkIO $ readFromSocketAndSendToTunnel sock (Wsi.TunnelConnection connCode) tunnel
  liftIO $ forkIO $ readFromTunnelAndSendToSocket sock (Wsi.TunnelConnection connCode) tunnel
  return ()
  where isOpenConnection op = case op of
                                Wsi.OpenConnection addr port -> Just (Nothing, (addr, port))
                                _                            -> Nothing

readFromSocketAndSendToTunnel :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromSocketAndSendToTunnel sock tc tref = do
--    print "Waiting for data from socket"
    bs <- liftIO $ Network.connectionGetChunk sock
--    print "Data received: "
    if Bs.null bs
      then warnConnectionClosed tc tref
      else Wsi.sendData' (toS bs) tc tref >> readFromSocketAndSendToTunnel sock tc tref

readFromTunnelAndSendToSocket :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromTunnelAndSendToSocket sock tc tref = do
--    print "Waiting for data from master"
    bs <- Wsi.recvDataFrom' tc tref
--    print "Data received: "
    case bs of
      Wsi.BytesOnly _ bs           -> liftIO (print bs) >> Network.connectionPut sock (toS bs) >> readFromTunnelAndSendToSocket sock tc tref
      Wsi.TunnelConnectionClosed _ -> print "Closing socket (Requested by master)" >> Network.connectionClose sock >> warnConnectionClosed tc tref