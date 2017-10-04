module Main where

import WsTunnel.Slave
import Control.Monad.IO.Class

main :: IO ()
main = connectToMaster "127.0.0.1" 8080 "/google" $ do
    lastMsg <- recvUnchanneledData
    liftIO $ print lastMsg
    return ()