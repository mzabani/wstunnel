{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module WsTunnel.Master (
    runMasterTunnelT
  , escapeMasterTunnel
  , MonadWsMasterTunnel(..)
  , WsMasterTunnelT
) where

import Data.Text
import Control.Monad.IO.Class
import Control.Monad.Catch
import Network.WebSockets
import Control.Concurrent.MVar
import Data.ByteString.Lazy
import Data.String.Conv
import qualified Data.ByteString as Bs
import qualified Data.Default.Class as Default
import qualified Network.TLS as TLS
import Network.TLS.Extra
import Network.HTTP.Client
import Data.X509.CertificateStore
import System.X509.Unix
import Control.Monad.Reader
import Control.Monad.Trans
import Control.Monad.Base
import Control.Monad.Trans.Control
import qualified WsTunnel.Internal as Wsi

newtype WsMasterTunnelT m a = WsMasterTunnelT (Wsi.TunnelT m a)

class MonadWsMasterTunnel m where
    openConnection :: Text -> Int -> m Wsi.TunnelConnection
    closeConnection :: Wsi.TunnelConnection -> m ()
    isTunnelOpen :: Wsi.TunnelConnection -> m Bool
    sendData :: ByteString -> Wsi.TunnelConnection -> m ()
    recvDataFrom :: Wsi.TunnelConnection -> m Wsi.ReceivedMessage
    recvUnchanneledData :: m ByteString
    sendUnchanneledData :: ByteString -> m ()
    recvAtMostFrom :: Int -> Wsi.TunnelConnection -> m ByteString
    wstunnelManagerSettings :: m ManagerSettings
    waitForAllConnections :: m ()
    getTunnel :: m Wsi.Tunnel

instance (MonadIO m, MonadThrow m) => MonadWsMasterTunnel (WsMasterTunnelT m) where
    openConnection addr port = WsMasterTunnelT $ Wsi.openConnection addr port
    closeConnection tc = WsMasterTunnelT $ Wsi.closeConnection tc
    isTunnelOpen tc = WsMasterTunnelT $ Wsi.isTunnelOpen tc
    sendData bs tc = WsMasterTunnelT $ Wsi.sendData bs tc
    recvDataFrom tc = WsMasterTunnelT $ Wsi.recvDataFrom tc
    recvUnchanneledData = WsMasterTunnelT Wsi.recvUnchanneledData
    sendUnchanneledData bs = WsMasterTunnelT $ Wsi.sendUnchanneledData bs
    recvAtMostFrom size tc = WsMasterTunnelT $ Wsi.recvAtMostFrom size tc
    wstunnelManagerSettings = wstunnelManagerSettings'
    waitForAllConnections = WsMasterTunnelT $ Wsi.waitForAllConnections
    getTunnel = WsMasterTunnelT Wsi.getTunnel

runMasterTunnelT :: (MonadIO m, MonadThrow m) => WsMasterTunnelT m a -> Connection -> m a
runMasterTunnelT (WsMasterTunnelT action) conn = Wsi.runTunnelT action conn

escapeMasterTunnel :: (MonadIO m, MonadThrow m) => Wsi.Tunnel -> WsMasterTunnelT m a -> m a
escapeMasterTunnel tun (WsMasterTunnelT tunAction) = Wsi.escapeTunnel tun tunAction

instance Functor m => Functor (WsMasterTunnelT m) where
    fmap f (WsMasterTunnelT v) = WsMasterTunnelT $ fmap f v

instance MonadIO m => Applicative (WsMasterTunnelT m) where
    pure = WsMasterTunnelT . pure
    (WsMasterTunnelT f) <*> (WsMasterTunnelT b) = WsMasterTunnelT (f <*> b)

instance MonadIO m => Monad (WsMasterTunnelT m) where
    return = WsMasterTunnelT . return
    (WsMasterTunnelT ta) >>= f = WsMasterTunnelT $ do
        v <- ta
        let (WsMasterTunnelT x) = f v in x

instance MonadIO m => MonadIO (WsMasterTunnelT m) where
    liftIO = WsMasterTunnelT . liftIO

instance (MonadIO m, MonadThrow m) => MonadThrow (WsMasterTunnelT m) where
    throwM = WsMasterTunnelT . throwM

instance (MonadIO m, MonadBase b m) => MonadBase b (WsMasterTunnelT m) where
  liftBase = liftBaseDefault

instance MonadTransControl WsMasterTunnelT where
  type StT WsMasterTunnelT a = StT Wsi.TunnelT a
  liftWith = defaultLiftWith WsMasterTunnelT (\(WsMasterTunnelT x) -> x)
  restoreT = defaultRestoreT WsMasterTunnelT

instance (MonadIO m, MonadBaseControl b m) => MonadBaseControl b (WsMasterTunnelT m) where
  type StM (WsMasterTunnelT m) a = ComposeSt WsMasterTunnelT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

instance MonadTrans WsMasterTunnelT where
  lift = WsMasterTunnelT . lift

instance (MonadIO m, MonadReader r m) => MonadReader r (WsMasterTunnelT m) where
  ask = WsMasterTunnelT $ lift ask
  local modf (WsMasterTunnelT (Wsi.TunnelT rm)) = WsMasterTunnelT . Wsi.TunnelT $ mapReaderT (local modf) rm

-- HTTP Client ManagerSettings
wstunnelManagerSettings' :: (MonadThrow m, MonadIO m) => WsMasterTunnelT m ManagerSettings
wstunnelManagerSettings' = do
  certStore <- liftIO $ getSystemCertificateStore
  tref <- getTunnel
  return $ defaultManagerSettings {
    managerRawConnection = openRawConn tref,
    managerTlsConnection = openTlsConn certStore tref
  }
    where openRawConn tref = return $ \_ addr port -> escapeMasterTunnel tref $ do
            -- liftIO $ Prelude.putStrLn $ "OPENING CONNECTION TO " ++ addr
            wsconn <- openConnection (Data.Text.pack addr) port
            -- liftIO $ Prelude.putStrLn "CONNECTION OPENED"
            conn <- liftIO $ makeConnection (rawRecvData wsconn) (rawSendData wsconn) (rawCloseConnection wsconn)
            return conn
            where
              rawRecvData tc = escapeMasterTunnel tref $ do
                                 msg <- recvDataFrom tc
                                 case msg of
                                   Wsi.TunnelConnectionClosed _ -> return Bs.empty
                                   Wsi.BytesOnly _ bs           -> return $ toS bs
              rawSendData tc bs = escapeMasterTunnel tref $ sendData (toS bs) tc
              rawCloseConnection tc = escapeMasterTunnel tref $ closeConnection tc
          openTlsConn cs tref = return $ \_ addr port -> escapeMasterTunnel tref $ do
            -- liftIO $ Prelude.putStrLn $ "OPENING CONNECTION TO " ++ addr
            tunConn <- openConnection (toS addr) port
            -- liftIO $ Prelude.putStrLn "CONNECTION OPENED"
            tlsContext <- TLS.contextNew (tlsBackend tunConn) (clientParams cs addr (toS (show port)))
            TLS.handshake tlsContext
            -- liftIO $ Prelude.putStrLn "HANDSHAKE DONE!"
            conn <- liftIO $ makeConnection (TLS.recvData tlsContext) (TLS.sendData tlsContext . toS) (TLS.bye tlsContext >> (escapeMasterTunnel tref $ closeConnection tunConn))
            return conn
              where
                clientParams cs addr port = (TLS.defaultParamsClient addr port) {
                  TLS.clientSupported = Default.def { TLS.supportedCiphers = ciphersuite_all }
                , TLS.clientShared = Default.def {
                    TLS.sharedCAStore = cs
                  , TLS.sharedValidationCache = Default.def
                  }
                }
                -- clientParams addr = TLS.ClientParams {
                --   TLS.clientUseMaxFragmentLength = Nothing,
                --   TLS.clientServerIdentification = (addr, undefined),
                --   TLS.clientUseServerNameIndication = False,
                --   TLS.clientWantSessionResume = Nothing,
                --   TLS.clientShared = TLS.Shared {
                --     TLS.sharedCredentials = TLS.Credentials [],
                --     TLS.sharedSessionManager = TLS.noSessionManager,
                --     TLS.sharedCAStore = certStore,
                --     TLS.sharedValidationCache = Default.def
                --   },
                --   TLS.clientHooks = Default.def,
                --   TLS.clientSupported = Default.def {
                --     TLS.supportedCiphers = ciphersuite_strong
                --   },
                --   TLS.clientDebug = Default.def
                -- }
                tlsBackend tunConn = TLS.Backend {
                  TLS.backendFlush = return (),
                  TLS.backendClose = escapeMasterTunnel tref $ closeConnection tunConn,
                  TLS.backendSend = \bs -> escapeMasterTunnel tref $ sendData (toS bs) tunConn,
                  {-TLS.backendSend = \bs -> escapeMasterTunnel tref $ do
                    -- liftIO $ Prelude.putStrLn $ "SEND: " ++ toS bs
                    sendData (toS bs) tunConn,-}
                  TLS.backendRecv = recvExactlyN
                  {-TLS.backendRecv = \n -> do
                    bs <- recvExactlyN n
                    -- liftIO $ Prelude.putStrLn $ "RECEIVED: " ++ show (Bs.length (toS bs))
                    return bs-}
                }
                  where recvExactlyN :: (MonadThrow m, MonadIO m) => Int -> m Bs.ByteString
                        recvExactlyN 0 = return Bs.empty
                        recvExactlyN numBytes = escapeMasterTunnel tref $ do
                          --liftIO $ Prelude.putStrLn $ "Want to receive " ++ show numBytes ++ " bytes"
                          -- liftIO $ print $ "Checking if tunnel " ++ show wsconn ++ " is open"
                          open <- isTunnelOpen tunConn
                          case open of
                            False -> error $ "Oops! Tunnel " ++ show tunConn ++ " isn't open!"
                            --False -> return Bs.empty
                            True -> do
                              --liftIO $ Prelude.putStrLn $ "Before receive! We need " ++ show numBytes
                              bytes <- fmap toS $ recvAtMostFrom numBytes tunConn
                              let bytesReceived = Bs.length bytes
                              --liftIO $ Prelude.putStrLn $ "After receive! Received " ++ show bytesReceived
                              if bytesReceived < numBytes then do
                                remaining <- recvExactlyN (numBytes - bytesReceived)
                                return $ Bs.concat [bytes, remaining]
                              else return bytes