{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
import Control.Monad.Reader
-- import Control.Monad.IO.Unlift
import qualified Data.Set as Set
import qualified Data.ByteString as Bs
import qualified Data.ByteString.Lazy as Lbs
import Control.Concurrent.Async

newtype WsSlaveT m a = WsSlaveT (Wsi.TunnelT m a)

class MonadWsSlaveTunnel m where
    -- processConnectionRequest :: m ()
    sendUnchanneledData :: Lbs.ByteString -> m ()
    recvUnchanneledData :: m Lbs.ByteString
    waitForAllConnections :: m ()
    getTunnel :: m Wsi.Tunnel

instance (MonadThrow m, MonadIO m) => MonadWsSlaveTunnel (WsSlaveT m) where
    -- processConnectionRequest = processConnectionRequest'
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

instance MonadIO m => MonadIO (WsSlaveT m) where
    liftIO = WsSlaveT . liftIO

connectToMaster :: String -> Int -> String -> WsSlaveT IO a -> IO a
connectToMaster host port path (WsSlaveT tunnelTAction) = runClient host port path clientApp
      where clientApp conn = Wsi.runTunnelT finalAction conn
            processRec tunnel = bracket_ (return ()) (return ()) (processConnectionRequest' tunnel) >> putStrLn "Received connection request" >> processRec tunnel
            finalAction = do
                tunnel <- Wsi.getTunnel
                liftIO $ print "Connecting to master!"
                liftIO $ forkIO (processRec tunnel)
                liftIO $ print "Connected to master!"
                tunnelTAction

warnConnectionClosed :: Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
warnConnectionClosed tc@(Wsi.TunnelConnection code) tunnel = do
  Prelude.putStrLn "Sending warnconnectionclosed"
  Wsi.sendOp' (Wsi.SocketClosed code) tunnel
  Wsi.removeConnection' tc tunnel

-- ^ Waits for the master to open a connection to some host. Returns when it is opened and guarantees
--   that the tunnel continues until either side decides to close the connection
processConnectionRequest' :: Wsi.Tunnel -> IO ()
processConnectionRequest' tunnel@(Wsi.Tunnel wsconn mvars _ _) = do
  connCtx <- Network.initConnectionContext
  -- print "Waiting for OpenConnection request"
  (addr, port) <- Wsi.recvUntil' isOpenConnection tunnel "{{ISOPENCONNECTION}}"
  print $ "Connecting to " ++ toS addr ++ " at port " ++ show port
  let connParams = Network.ConnectionParams {
        Network.connectionHostname = toS addr,
        Network.connectionPort = fromIntegral port,
        Network.connectionUseSecure = Nothing,
        Network.connectionUseSocks = Nothing
    }
  forkIO $ bracket (Network.connectTo connCtx connParams) (Network.connectionClose) $ \sock -> do
    print "Connected!"
    connCode <- modifyMVar mvars (\t@(connSet, msgQueue, lastCode) -> return $ ((connSet, msgQueue, lastCode + 1), lastCode + 1))
    let tunConn = Wsi.TunnelConnection connCode
    Wsi.addConnection' tunConn tunnel
    Wsi.sendOp' (Wsi.ConnectionOpened connCode) tunnel
    withAsync (readFromSocketAndSendToTunnel sock tunConn tunnel) $ \as1 -> do
        withAsync (readFromTunnelAndSendToSocket sock tunConn tunnel) $ \as2 -> do
            let recvSocketClosed op = case op of
                                        Wsi.SocketClosed connCode -> Just (Nothing, ())
                                        _                         -> Nothing
              in Wsi.recvUntil' recvSocketClosed tunnel "{{SOCKET CLOSED FROM OTHER SIDE}}"
            print "Received SocketClosed from master"
            warnConnectionClosed tunConn tunnel
            cancel as1
            cancel as2
            print "All done"
    return ()
  return ()
    where isOpenConnection op = case op of
                                    Wsi.OpenConnection addr port -> Just (Nothing, (addr, port))
                                    _                            -> Nothing

readFromSocketAndSendToTunnel :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromSocketAndSendToTunnel sock tc tref = do
    -- print "Waiting for data from socket"
    bs <- Network.connectionGetChunk sock
    --    print "Data received: "
    if Bs.null bs
    then print "EMPTY BYTESTRING CHUNK!" >> warnConnectionClosed tc tref
    else Wsi.sendData' (toS bs) tc tref >> readFromSocketAndSendToTunnel sock tc tref

readFromTunnelAndSendToSocket :: Network.Connection -> Wsi.TunnelConnection -> Wsi.Tunnel -> IO ()
readFromTunnelAndSendToSocket sock tc tref = do
    bs <- Wsi.recvDataFrom' tc tref
    case bs of
      Wsi.BytesOnly _ bs           -> Network.connectionPut sock (toS bs) >> readFromTunnelAndSendToSocket sock tc tref
      Wsi.TunnelConnectionClosed _ -> print "Closing socket (Requested by master)" >> Network.connectionClose sock >> warnConnectionClosed tc tref