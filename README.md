WsTunnel
===

This library allows a program to connect to another program which will then use the first as a proxy for TCP connections. All of this happens over a Websocket connection, hence the library's name, *WsTunnel*.
The program that connects and allows itself to open connections for the other is from now on called the *Slave*, and the program that was waiting for someone to connect and that has the power to make the *Slave* open connections is the *Master*. *Master* and *Slave* can also exchange data between themselves (not a connection to some other host) and both of them can close the connection at anytime.
  

What follows are two programs that communicate with each other and show WsTunnel's main (or perhaps even all) features.

The Slave
---
    {-# LANGUAGE OverloadedStrings #-}
    import WsTunnel.Slave
    import Data.ByteString

    main =
      -- Suppose the master is listening on localhost on port 80 at ws://localhost:80/wspath
      connectToMaster "localhost" 80 "/wspath" $ do
        sendUnchanneledData "Hi master. Feel free to open connections at any time and send me a message when you're done"
        msgEnding <- recvUnchanneledData
        print msgEnding

The Master
---
    {-# LANGUAGE OverloadedStrings #-}
    import WsTunnel.Master
    import Data.ByteString
    import Control.Monad.IO.Class
    import Network.HTTP.Client
    import qualified Network.WebSockets as Ws

    main = undefined -- Here you're supposed to set up a websockets server of your preference in a way that runs the function "becomeMaster" with the function "runMasterTunnelT" for websocket requests to /wspath. An example on how to do this with Warp is available in the next section

    becomeMaster :: Ws.Connection -> IO ()
    becomeMaster wsConn = runMasterTunnelT wsConn $ do
      slavesMsg <- recvUnchanneledData
      -- The wstunnelManagerSettings returns a ManagerSettings that leads to http and https connections that are opened by the Slave.
      -- It is very important to remember that although the Slave can't decrypt https traffic, it will know the address and port
      -- that we're connecting to and it will have access to all the traffic in case of plain http connections!
      httpMgrSettings <- wstunnelManagerSettings
      httpMgr <- liftIO $ newManager httpMgrSettings
      req <- liftIO $ parseRequest "http://someurl.com/some-path/"
      response <- liftIO $ httpLbs req httpMgr
      print response
      Master.sendUnchanneledData "Done!"

Creating a websocket server with Warp
---

Here we'll show you a way to receive websocket connections with Warp alongside your current Warp application. This is probably not the best way to do this but it is _one_ way.

    {-# LANGUAGE OverloadedStrings #-}
    import Data.Text
    import Network.Wai
    import Network.Wai.Handler.Warp
    import Control.Exception.Safe
    import qualified Network.WebSockets as Ws
    import qualified Network.Wai.Handler.WebSockets as Ws

    -- | Add your actions to this on a per-path basis. "becomeMaster" is the function from the Master's code sample
    websocketsUrls :: [(Text, Ws.Connection -> IO ())]
    websocketsUrls = [("path1", undefined), ("path2/file", undefined), ("wspath", becomeMaster)]

    websocketsUrl :: Application -> Application
    websocketsUrl previousApp req respond = do
      case Ws.websocketsApp Ws.defaultConnectionOptions (wsApp req) req of
        Nothing       -> previousApp req respond
        Just response -> respond response

    -- Ws.ServerApp is PendingConnection -> IO ()
    wsApp :: Request -> Ws.ServerApp
    wsApp req pendingConn = do
      let path = intercalate "/" (pathInfo req)
      case lookup path websocketsUrls of
        Nothing -> return ()
        Just f  -> do
          wsConnMaybe <- tryAny $ Ws.acceptRequest pendingConn
          case wsConnMaybe of
            Left exc     -> Prelude.putStrLn "Error when accepting the websockets connection"
            Right wsConn -> do
              catchAny (f wsConn) logException
                where logException exc = Prelude.putStrLn $ (unpack path) ++ ": Exception: " ++ show exc
    
    -- | This is your current definition of Application
    yourCurrentServerApp :: Application
    yourCurrentServerApp = undefined

    -- | Here we put every request to be checked against the paths defined in "websocketsUrls". If none of them
    -- match the request's path it is delegated to your current application
    main = run 80 (websocketsUrl yourCurrentServerApp)