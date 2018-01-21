{-# LANGUAGE OverloadedStrings #-}
module WsTunnelSpec where

import Test.Hspec
import qualified WsTunnel.Master as Master
import qualified WsTunnel.Slave as Slave
import Data.ByteString.Lazy
import Control.Exception.Safe
import WsTunnel
import Control.Monad.IO.Class
import Data.Traversable
import Network.Wai
import Network.Wai.Handler.Warp
import Network.HTTP.Types.Status
import Network.HTTP.Client
import Control.Concurrent.MVar
import Data.String.Conv
import qualified Network.WebSockets as Ws
import qualified Network.Wai.Handler.WebSockets as Ws

runMasterAndSlave :: (Show a, Show b) => WsMasterTunnelT IO a -> WsSlaveT IO b -> IO (a, b)
runMasterAndSlave masterAction slaveAction = do
    masterResultsMVar <- newEmptyMVar
    testWithApplication (return $ runWebServer masterResultsMVar masterAction) $ \port -> do
        --Prelude.putStrLn "0"
        slaveResults <- connectToMaster "localhost" port "/any-path" slaveAction
        --Prelude.putStrLn "2"
        masterResults <- takeMVar masterResultsMVar
        --Prelude.putStrLn "4"
        --print (masterResults, slaveResults) 
        return (masterResults, slaveResults)
    
-- Application is Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
runWebServer :: MVar a -> WsMasterTunnelT IO a -> Application
runWebServer mvarResult action req respond = do
    -- Ws.ServerApp is PendingConnection -> IO ()
    let wsapp :: Ws.ServerApp
        wsapp pendingConn = do
          wsConn <- Ws.acceptRequest pendingConn
          res <- runMasterTunnelT wsConn action
          --Prelude.putStrLn "1" 
          putMVar mvarResult res
          --Prelude.putStrLn "3"
    case Ws.websocketsApp Ws.defaultConnectionOptions wsapp req of
        Nothing       -> error "Not a websocket request!"
        Just response -> respond response

runRegularWebserverWithPagesContents :: ByteString -> Application
runRegularWebserverWithPagesContents contents req respond = respond $ responseLBS status200 [] contents

spec :: Spec
spec = 
  describe "Testing all sorts of usage of WsTunnel" $ do
    it "Bidirectional communication works normally - one message each" $ do
      let slaveAction = do
            Slave.sendUnchanneledData "slave"
            Slave.recvUnchanneledData
          masterAction = do
            Master.sendUnchanneledData "master"
            Master.recvUnchanneledData
      res <- runMasterAndSlave masterAction slaveAction
      res `shouldBe` ("slave", "master")
    it "Bidirectional communication works normally - send, receive ack, increment and send again" $ do
      let slaveAction = do
            allAcks <- forM [1..10] $ \i -> do
              Slave.sendUnchanneledData $ toS (show i)
              ack <- Slave.recvUnchanneledData
              case ack of
                "ok" -> return ack
                _    -> error "Ack is wrong!"
            return $ lastElement allAcks
          masterAction =
            forM [1..10] $ \i -> do
              ibs <- Master.recvUnchanneledData
              if toS (show i) == ibs
                then Master.sendUnchanneledData "ok" >> return ibs
                else error "Wrong number!"
      res <- runMasterAndSlave masterAction slaveAction
      res `shouldBe` (fmap (toS . show) [1..10], Just "ok")
    it "waitForAllConnections returns immediatelly when there is nothing to wait for" $ do
      r <- tryAsync $ runMasterAndSlave Master.waitForAllConnections Slave.waitForAllConnections
      case r of
        Left e -> print (e :: SomeException)
        Right res -> res `shouldBe` ((), ())
    it "http connection going through the tunnel works" $ do
      let pageContents = "Hello WsTunnel"
      testWithApplication (return $ runRegularWebserverWithPagesContents pageContents) $ \httpServerPort -> do
        let masterAction = do
              httpMgrSettings <- Master.wstunnelManagerSettings
              httpMgr <- liftIO $ newManager httpMgrSettings
              req' <- liftIO $ parseRequest "http://localhost/"
              response <- liftIO $ httpLbs (req' { port = httpServerPort }) httpMgr
              Master.sendUnchanneledData "Done!"
              return response
        res <- tryAsync $ runMasterAndSlave masterAction Slave.recvUnchanneledData
        case res of
          Left e -> Prelude.putStrLn (show (e :: SomeException))
          Right r -> do
            let (httpResponse, mastersLastMsg) = r
            responseBody httpResponse `shouldBe` pageContents
            mastersLastMsg `shouldBe` "Done!"


lastElement :: [a] -> Maybe a
lastElement [] = Nothing
lastElement (x:[]) = Just x
lastElement (x:xs) = lastElement xs