module WsTunnel  (
  runMasterTunnelT
  , escapeMasterTunnel
  , connectToMaster
  , TunnelConnection
  , TunnelException
  , WsMasterTunnelT
  , Tunnel
--  , MonadWsMasterTunnel(..)
--  , MonadWsSlaveTunnel(..)
  , ReceivedMessage(..)
  ) where

import WsTunnel.Internal (Tunnel, TunnelConnection(..), TunnelException(..), ReceivedMessage(..))
import WsTunnel.Master
import WsTunnel.Slave