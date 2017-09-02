module Main where

import WsTunnel.Slave

main :: IO ()
main = connectToMaster "127.0.0.1" 8080 "/extrato" $ do
    let creds = Credenciais { }
    sendUnchanneledData $ encode 
    processConnectionRequest -- Login
    processConnectionRequest -- Extrato
    waitForAllConnections