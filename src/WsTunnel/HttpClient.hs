module WsTunnel.HttpClient (
  wstunnelManagerSettings) where

import Network.HTTP.Client
import Network.HTTP.Client.Internal
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_strong)
import WsTunnel
import Data.Text
import Control.Monad.IO.Class
import Control.Monad.Catch
import Control.Concurrent.MVar
import qualified Data.ByteString as Bs
import Data.ByteString.Lazy (toStrict, fromStrict)
import qualified Data.Default.Class as Default
import qualified Data.X509.CertificateStore as Cert
import qualified Data.ByteString.Char8 as Bsc
import System.X509

wstunnelManagerSettings :: (MonadThrow m, MonadIO m) => MVar Tunnel -> m ManagerSettings
wstunnelManagerSettings tref = do
  certStore <- liftIO $ getSystemCertificateStore
  return $ defaultManagerSettings {
    managerRawConnection = openTlsConn certStore tref,
    managerTlsConnection = openTlsConn certStore tref
  }
    where openTlsConn cs tref = return $ \_ addr port -> escapeTunnel tref $ do
            liftIO $ Prelude.putStrLn $ "OPENING CONNECTION TO " ++ addr
            wsconn <- openConnection (pack addr) port
            liftIO $ Prelude.putStrLn "CONNECTION OPENED"
            tlsContext <- TLS.contextNew (tlsBackend wsconn) (clientParams cs addr (Bsc.pack (show port)))
            TLS.handshake tlsContext
            liftIO $ Prelude.putStrLn "HANDSHAKE DONE!"
            -- TODO: exception for closed connection!
            -- The line below is only for non-TLS connections!
            --conn <- liftIO $ makeConnection (connRead tref wsconn) (connWrite tref wsconn) (connClose tref wsconn)
            conn <- liftIO $ makeConnection (TLS.recvData tlsContext) (TLS.sendData tlsContext . fromStrict) (TLS.bye tlsContext)
            return conn
              where
                clientParams cs addr port = (TLS.defaultParamsClient addr port) {
                  TLS.clientSupported = Default.def { TLS.supportedCiphers = ciphersuite_strong }
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
                tlsBackend wsconn = TLS.Backend {
                  TLS.backendFlush = return (),
                  TLS.backendClose = escapeTunnel tref $ closeConnection wsconn,
                  TLS.backendSend = \bs -> escapeTunnel tref $ do
                    --liftIO $ Prelude.putStrLn $ "SEND: " ++ Bsc.unpack bs
                    sendData (fromStrict bs) wsconn,
                  TLS.backendRecv = \n -> do
                    bs <- recvExactlyN n
                    --liftIO $ Prelude.putStrLn $ "RECEIVED: " ++ Bsc.unpack bs
                    return bs
                }
                  where recvExactlyN :: (MonadThrow m, MonadIO m) => Int -> m Bs.ByteString
                        recvExactlyN 0 = return Bs.empty
                        recvExactlyN numBytes = escapeTunnel tref $ do
                          --liftIO $ Prelude.putStrLn $ "Want to receive " ++ show numBytes ++ " bytes"
                          open <- isTunnelOpen wsconn
                          case open of
                            False -> error "Oops! Tunnel isn't open!"
                            True -> do
                              msg <- recvDataFrom wsconn
                              case msg of
                                TunnelConnectionClosed _ -> error "What should we do here? The tunnel was closed on a read attempt!"
                                BytesOnly _ lbs -> do
                                  -- Push back excess bytes if there are any and receive remaining if we are not there yet
                                  let bs = toStrict lbs
                                  let bytesReceived = Bs.length bs
                                  if bytesReceived > numBytes then do
                                    let excess = fromStrict $ Bs.drop numBytes bs
                                    --liftIO $ Prelude.putStrLn $ "Unreceiving " ++ show (bytesReceived - numBytes) ++ " bytes!"
                                    unrecvData wsconn excess
                                    return $ Bs.take numBytes bs
                                  else do
                                    --liftIO $ Prelude.putStrLn $ "Received " ++ show bytesReceived ++ " bytes. " ++ show (numBytes - bytesReceived) ++ " remaining"
                                    remaining <- recvExactlyN (numBytes - bytesReceived)
                                    return $ Bs.concat [bs, remaining]
                -- The lines below are for unprotected connections!
                -- connRead tref wsconn = escapeTunnel tref $ do
                --     open <- isTunnelOpen wsconn
                --     case open of
                --       False -> error "Oops!"
                --       True -> do
                --         msg <- recvDataFrom wsconn
                --         case msg of
                --           BytesOnly _ bs -> return $ toStrict bs
                --           TunnelConnectionClosed _ -> return  Bs.empty
                -- connWrite tref wsconn = \bs -> escapeTunnel tref $ sendData (fromStrict bs) wsconn
                -- connClose tref wsconn = escapeTunnel tref $ closeConnection wsconn
                --, connectionUnread = \bs -> escapeTunnel tref $ unrecvData (BytesOnly wsconn (fromStrict bs))