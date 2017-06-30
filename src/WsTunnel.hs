{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE UndecidableInstances #-}
--{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BangPatterns #-}
module WsTunnel  (
  runTunnelT
  , escapeTunnel
  , TunnelConnection
  , TunnelException
  , TunnelT
  , Tunnel
  , MonadWsTunnel(..)
  , ReceivedMessage(..)
  , printTunnel
  ) where

import GHC.Generics
import Data.Aeson
import Prelude hiding (length, take, drop, putStr, null, map)
import Control.Applicative ((<|>))
import qualified Data.Text as T
import Data.Text.Lazy.Encoding (encodeUtf8)
import Data.Text.Lazy (fromStrict)
import Data.Typeable
import Data.ByteString.Lazy hiding (empty, null, take, repeat, find)
import qualified Data.ByteString.Builder as BsBuild
import Network.WebSockets
import Control.Monad.IO.Class
import Control.Monad.Catch
import Data.Monoid ((<>))
import Control.Monad.State.Lazy
import Control.Monad.Reader
import qualified Data.Set as Set
import qualified Data.Sequence as Seq
import Data.Attoparsec.ByteString hiding (repeat, find)
import Data.Foldable (find, toList)
import Data.Word
import Control.Concurrent.MVar
import Control.Monad.Trans.Control
import Control.Monad.Base

-- Here we define our MonadWsTunnel typeclass and our TunnelT monad transformer, along with some instances to ease the creation of typical monad stacks
class MonadWsTunnel m where
  openConnection :: T.Text -> Int -> m TunnelConnection
  closeConnection :: TunnelConnection -> m ()
  isTunnelOpen :: TunnelConnection -> m Bool
  sendData :: ByteString -> TunnelConnection -> m ()
  recvData :: m ReceivedMessage
  recvDataFrom :: TunnelConnection -> m ReceivedMessage
  unrecvData :: TunnelConnection -> ByteString -> m ()
  sendUnchanneledData :: ByteString -> m ()
  recvUnchanneledData :: m ByteString
  waitForAllConnections :: m ()
  getTunnelRef :: m (MVar Tunnel)

instance (MonadThrow m, MonadIO m) => MonadWsTunnel (TunnelT m) where
  openConnection = openConnection'
  closeConnection = closeConnection'
  isTunnelOpen = isTunnelOpen'
  sendData = sendData'
  recvData = recvData'
  recvDataFrom = recvDataFrom'
  unrecvData = unrecvData'
  sendUnchanneledData = sendUnchanneledData'
  recvUnchanneledData = recvUnchanneledData'
  waitForAllConnections = waitForAllConnections'
  getTunnelRef = getTunnelRef'

printTunnel :: (MonadThrow m, MonadIO m) => TunnelT m ()
printTunnel = do
  mvt <- getTunnelRef
  Tunnel _ connSet msgQueue <- liftIO $ readMVar mvt
  liftIO $ Prelude.putStrLn $ "(" ++ show (Set.size connSet) ++ ", " ++ show (Seq.length msgQueue) ++ ")"

-- This MonadTransformer is just like (StateT Tunnel)..
newtype TunnelT m a = TunnelT (ReaderT (MVar Tunnel) m a)

instance Functor m => Functor (TunnelT m) where
  fmap f (TunnelT rm) = TunnelT $ fmap f rm

instance MonadIO m => Applicative (TunnelT m) where
  pure = return
  (TunnelT f) <*> (TunnelT sm) = TunnelT $ f <*> sm

instance MonadIO m => Monad (TunnelT m) where
  return = TunnelT . return
  TunnelT sma >>= f = TunnelT $ do
    v <- sma
    let (TunnelT x) = f v in x

getTunnel :: (MonadThrow m,MonadIO m) => TunnelT m Tunnel
getTunnel = do
  mvt <- getTunnelRef
  tun <- liftIO $ readMVar mvt
  return tun

putTunnel :: (MonadThrow m, MonadIO m) => Tunnel -> TunnelT m ()
putTunnel !t = do
  mvt <- getTunnelRef
  !nt <- liftIO $ swapMVar mvt t
  return ()

addConnection :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m ()
addConnection (TunnelConnection code) = do
  Tunnel conn connSet msgQueue <- getTunnel
  putTunnel $ Tunnel conn (Set.insert code connSet) msgQueue

deleteOpAt :: (MonadThrow m, MonadIO m) => Int -> TunnelT m ()
deleteOpAt idx = do
  Tunnel conn connSet msgQueue <- getTunnel
  putTunnel $ Tunnel conn connSet $ deleteAt idx msgQueue

addOpToQueue :: (MonadThrow m, MonadIO m) => Operation -> TunnelT m ()
addOpToQueue op = do
  Tunnel conn connSet msgQueue <- getTunnel
  putTunnel $ Tunnel conn connSet $ msgQueue Seq.|> op

instance (MonadIO m, MonadBase b m) => MonadBase b (TunnelT m) where
  liftBase = liftBaseDefault

instance MonadTransControl TunnelT where
  type StT TunnelT a = StT (ReaderT (MVar Tunnel)) a
  liftWith = defaultLiftWith TunnelT (\(TunnelT x) -> x)
  restoreT = defaultRestoreT TunnelT

instance (MonadIO m, MonadBaseControl b m) => MonadBaseControl b (TunnelT m) where
  type StM (TunnelT m) a = ComposeSt TunnelT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

instance MonadTrans TunnelT where
  lift = TunnelT . lift

instance (MonadIO m, MonadReader r m) => MonadReader r (TunnelT m) where
  ask = TunnelT $ lift ask
  local modf (TunnelT rm) = TunnelT $ mapReaderT (local modf) rm

instance MonadIO m => MonadIO (TunnelT m) where
  liftIO = TunnelT . liftIO
instance (MonadIO m, MonadThrow m) => MonadThrow (TunnelT m) where
  throwM = TunnelT . throwM

data Tunnel = Tunnel !Connection !(Set.Set Word8) !(Seq.Seq Operation)
newtype TunnelConnection = TunnelConnection Word8 deriving (Eq)
data ConnectionRequest = ConnectionRequest { address :: T.Text, port :: Int } deriving (Generic, ToJSON)

data TunnelException = ErrorWhenOpeningConnection | ErrorWhenReceivingData deriving (Typeable, Show)
instance Exception TunnelException

data Operation = OpenConnection T.Text Int | Message Word8 ByteString | SocketClosed Word8 | ConnectionOpened Word8 | UnchanneledMessage ByteString | EndTunnel  deriving (Show)

-- ^ Converts an operation to its binary representation, always leaving 8 bytes in the end for future versions of the protocol
toBinaryRepresentation :: Operation -> ByteString
toBinaryRepresentation (OpenConnection addr port) = BsBuild.toLazyByteString (BsBuild.word8 0 <> BsBuild.int64BE 0) <> encode ConnectionRequest { address = addr, port = port }
toBinaryRepresentation (Message connId bs) = BsBuild.toLazyByteString (BsBuild.word8 1 <> BsBuild.int64BE 0 <> BsBuild.word8 connId) <> bs
toBinaryRepresentation (SocketClosed i) = BsBuild.toLazyByteString $ BsBuild.word8 2 <> BsBuild.word8 i <> BsBuild.int64BE 0
toBinaryRepresentation (ConnectionOpened code) = BsBuild.toLazyByteString $ BsBuild.word8 3 <> BsBuild.word8 code <> BsBuild.int64BE 0
toBinaryRepresentation EndTunnel = BsBuild.toLazyByteString $ BsBuild.word8 4 <> BsBuild.int64BE 0
toBinaryRepresentation (UnchanneledMessage bs) = BsBuild.toLazyByteString (BsBuild.word8 5 <> BsBuild.int64BE 0) <> bs

-- ^ Remove this in future versions of "container"
deleteAt :: Int -> Seq.Seq a -> Seq.Seq a
deleteAt idx s = Seq.take idx s Seq.>< Seq.drop (idx + 1) s

deleteFirst :: (Eq a) => a -> Seq.Seq a -> Seq.Seq a
deleteFirst el s = case findWithIdx (==el) 0 (toList s) of
                     Nothing     -> s
                     Just (_, i) -> deleteAt i s

findWithIdx :: (a -> Bool) -> Int -> [a] -> Maybe (a, Int)
findWithIdx pred i (x:xs) = if pred x then Just (x, i) else findWithIdx pred (i + 1) xs
findWithIdx _    _ []     = Nothing

-- ^ Receives data from some tunnel connection (you can't pick which) and returns it, while updating the connection set (but not the message queue)
recvOp :: (MonadThrow m, MonadIO m) => TunnelT m Operation
recvOp = do
  Tunnel conn connSet msgQueue <- getTunnel
  -- TODO: bracket and throwM
  dataMsg <- liftIO $ receiveDataMessage conn
  case dataMsg of
    Text _     -> throwM ErrorWhenReceivingData
    Binary msg -> do
      case parseOnly ((messageParser <|> connectionOpenedParser <|> socketClosedParser <|> unchanneledMessageParser) <* endOfInput) (toStrict msg) of
        Left _   -> throwM ErrorWhenReceivingData
        Right op -> do
          --liftIO . Prelude.putStrLn $ "Received operation " ++ show op
          case op of
            SocketClosed code -> do
              putTunnel $ Tunnel conn (Set.delete code connSet) msgQueue
              liftIO . Prelude.putStrLn $ "-- Closed tunnel of code " ++ show code
              return op
            ConnectionOpened code -> do
              -- liftIO $ Prelude.putStrLn $ "Tunnel opened"
              addConnection (TunnelConnection code)
              return op
            _                 -> return op

sendOp :: (MonadThrow m, MonadIO m) => Operation -> TunnelT m ()
sendOp op = do
  Tunnel conn _ _ <- getTunnel
  -- TODO: bracket and throwM
  liftIO $ sendDataMessage conn $ Binary (toBinaryRepresentation op)
  --printTunnel
  return ()

messageParser :: Parser Operation
messageParser = do
  word8 1
  connId <- anyWord8
  _ <- take 8
  msg <- takeLazyByteString
  return $ Message connId msg

socketClosedParser :: Parser Operation
socketClosedParser = do
  word8 2
  connId <- anyWord8
  _ <- take 8
  return $ SocketClosed connId

connectionOpenedParser :: Parser Operation
connectionOpenedParser = do
  word8 3
  code <- anyWord8
  _ <- take 8
  return $ ConnectionOpened code

unchanneledMessageParser :: Parser Operation
unchanneledMessageParser = do
  word8 5
  _ <- take 8
  msg <- takeLazyByteString
  return $ UnchanneledMessage msg

-- ^ Waits for all opened connections to end and ends the tunnel
waitForAllConnections' :: (MonadThrow m, MonadIO m) => TunnelT m ()
waitForAllConnections' = do
  (Tunnel _ connSet _) <- getTunnel
  if Set.null connSet then sendOp EndTunnel >> return () else recvUntil (const True) >> waitForAllConnections

runTunnelT :: (MonadThrow m, MonadIO m) => TunnelT m a -> Connection -> m a
runTunnelT (TunnelT rm) conn = do
  -- TODO: bracket and throwM
  t <- liftIO $ newMVar $ Tunnel conn Set.empty Seq.empty
  runReaderT rm t

escapeTunnel :: (MonadThrow m, MonadIO m) => MVar Tunnel -> TunnelT m a -> m a
escapeTunnel iot t = runReaderT rm iot
  where (TunnelT rm) = t
--escapeTunnel iot (TunnelT rm) = runReaderT rm iot

-- ^ Looks for the first received operation in the msgQueue that satisfies the predicate. If one isn't found, receives messages (while putting them in the queue) until it is found, removes it from the msgQueue and returns it
recvUntil :: (MonadThrow m, MonadIO m) => (Operation -> Bool) -> TunnelT m Operation
recvUntil pred = do
  (Tunnel _ _ msgQueue) <- getTunnel
  case findWithIdx pred 0 (toList msgQueue) of
    Just (msg, idx) -> do
      deleteOpAt idx
      return msg
    Nothing         -> do
      op <- recvOp
      addOpToQueue op
      recvUntil pred

openConnection' :: (MonadThrow m, MonadIO m) => T.Text -> Int -> TunnelT m TunnelConnection
openConnection' addr port = do
  sendOp (OpenConnection addr port)
  idmsg <- recvUntil isConnOpened
  case idmsg of
    (ConnectionOpened code) -> do
      liftIO $ Prelude.putStrLn $ "++ Tunnel of Code " ++ show code ++ " opened!"
      return $ TunnelConnection code
    _                       -> throwM ErrorWhenOpeningConnection
    where isConnOpened (ConnectionOpened _) = True
          isConnOpened _                    = False

data ReceivedMessage = BytesOnly TunnelConnection ByteString | TunnelConnectionClosed TunnelConnection
recvData' :: (MonadThrow m, MonadIO m) => TunnelT m ReceivedMessage
recvData' = do
  op <- recvUntil isDesired
  case op of
    Message code msg  -> return $ BytesOnly (TunnelConnection code) msg
    SocketClosed code -> return $ TunnelConnectionClosed (TunnelConnection code)
    _                 -> throwM ErrorWhenReceivingData

  where isDesired (Message _ _)    = True
        isDesired (SocketClosed _) = True
        isDesired _                = False

recvDataFrom' :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m ReceivedMessage
recvDataFrom' tc = do
  msg <- recvData'
  case msg of
    BytesOnly tc' _             -> if tc' == tc then return msg else recvDataFrom' tc
    TunnelConnectionClosed tc'  -> if tc' == tc then return msg else recvDataFrom' tc

recvUnchanneledData' :: (MonadThrow m, MonadIO m) => TunnelT m ByteString
recvUnchanneledData' = do
  op <- recvUntil (\msg -> case msg of UnchanneledMessage _ -> True
                                       _                    -> False)
  case op of
    UnchanneledMessage bs -> return bs
    _                     -> throwM ErrorWhenReceivingData

unrecvData' :: (MonadThrow m, MonadIO m) => TunnelConnection -> ByteString -> TunnelT m ()
unrecvData' (TunnelConnection code) bs = do
  Tunnel conn connSet msgQueue <- getTunnel
  let op = Message code bs
  putTunnel $ Tunnel conn connSet (op Seq.<| msgQueue)

sendUnchanneledData' :: (MonadThrow m, MonadIO m) => ByteString -> TunnelT m ()
sendUnchanneledData' bs = sendOp $ UnchanneledMessage bs

sendData' :: (MonadThrow m, MonadIO m) => ByteString -> TunnelConnection -> TunnelT m ()
sendData' msg (TunnelConnection code) = do
  --liftIO $ Prelude.putStrLn $ "Sending message to connection of code " ++ show code ++ ": " ++ show msg
  sendOp $ Message code msg

closeConnection' :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m ()
closeConnection' tc = error "closeConnection not implemented"

isTunnelOpen' :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m Bool
isTunnelOpen' (TunnelConnection tc) = do
  Tunnel _ connSet _ <- getTunnel
  --liftIO $ Prelude.putStrLn $ "Length of connectionset is " ++ show (Set.size connSet)
  return $ tc `Set.member` connSet

getTunnelRef' :: MonadIO m => TunnelT m (MVar Tunnel)
getTunnelRef' = TunnelT $ do
  iot <- ask
  return iot