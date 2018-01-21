module WsTunnel  (
  runMasterTunnelT
  , escapeMasterTunnel
  , connectToMaster
  , TunnelConnection
  , TunnelException
  , WsMasterTunnelT
  , WsSlaveT
  , Tunnel
  , ReceivedMessage(..)
  ) where

import WsTunnel.Internal (Tunnel, TunnelConnection(..), TunnelException(..), ReceivedMessage(..))
import WsTunnel.Master
import WsTunnel.Slave