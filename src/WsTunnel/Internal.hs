{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module WsTunnel.Internal where

import GHC.Generics
import Data.Aeson
import Data.Typeable
import Network.WebSockets
import Data.Foldable (toList)
import Data.ByteString.Lazy hiding (empty, null, take, repeat, find)
import Data.Word
import Control.Exception.Safe hiding (throwM, MonadThrow, catch, MonadCatch)
import Control.Monad.Catch (throwM, MonadThrow, MonadCatch, catch)
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans
import Control.Monad.Base
import Control.Monad.Trans.Control
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Data.String.Conv
import System.IO.Unsafe (unsafePerformIO)
import Data.Monoid ((<>))
import Control.Applicative ((<|>))
import Data.Attoparsec.ByteString hiding (repeat, find, try)
import Prelude hiding (length, take, drop, putStr, null, map, splitAt)
import qualified Data.Text as T
import qualified Data.ByteString.Builder as BsBuild
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

-- SENDING AND RECEIVING DATA DIRECTLY TO AND FROM CONNECTIONS (PARSING AND ENCODING OUR TYPES)
newtype TunnelConnection = TunnelConnection Word8 deriving (Eq, Show)
data ConnectionRequest = ConnectionRequest { address :: T.Text, port :: Int } deriving (Generic, ToJSON, FromJSON)

data Operation = OpenConnection T.Text Int | Message Word8 ByteString | SocketClosed Word8 | ConnectionOpened Word8 | UnchanneledMessage ByteString | EndTunnel  deriving (Show)
data TunnelException = ErrorWhenOpeningConnection | ErrorWhenReceivingData deriving (Typeable, Show)
instance Exception TunnelException

-- ^ Converts an operation to its binary representation, always leaving 8 bytes in the end for future versions of the protocol
toBinaryRepresentation :: Operation -> ByteString
toBinaryRepresentation (OpenConnection addr port) = BsBuild.toLazyByteString (BsBuild.word8 0 <> BsBuild.int64BE 0 <> BsBuild.word8 0) <> encode ConnectionRequest { address = addr, port = port }
toBinaryRepresentation (Message connId bs) = BsBuild.toLazyByteString (BsBuild.word8 1 <> BsBuild.word8 connId <> BsBuild.int64BE 0) <> bs
toBinaryRepresentation (SocketClosed connId) = BsBuild.toLazyByteString $ BsBuild.word8 2 <> BsBuild.word8 connId <> BsBuild.int64BE 0
toBinaryRepresentation (ConnectionOpened connId) = BsBuild.toLazyByteString $ BsBuild.word8 3 <> BsBuild.word8 connId <> BsBuild.int64BE 0
toBinaryRepresentation EndTunnel = BsBuild.toLazyByteString $ BsBuild.word8 4 <> BsBuild.int64BE 0 <> BsBuild.word8 0
toBinaryRepresentation (UnchanneledMessage bs) = BsBuild.toLazyByteString (BsBuild.word8 5 <> BsBuild.int64BE 0 <> BsBuild.word8 0) <> bs

sendOp' :: (MonadThrow m, MonadIO m) => Operation -> Tunnel -> m ()
sendOp' op (Tunnel conn tvars) = do
  liftIO $ sendDataMessage conn $ Binary (toBinaryRepresentation op)
  case op of
    SocketClosed code -> liftIO $ atomically $ modifyTVar' tvars (\(cset, msgqueue, lastCode) -> (Set.delete code cset, msgqueue, lastCode))
    _                 -> return ()

openConnectionParser :: Parser Operation
openConnectionParser = do
  word8 0
  _ <- take 9
  jsonText <- takeLazyByteString
  case eitherDecode jsonText of
    Left _                      -> fail "Error parsing Json Address and Port"
    Right ConnectionRequest{..} -> return $ OpenConnection address port

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

endTunnelParser :: Parser Operation
endTunnelParser = do
  word8 4
  _ <- take 9
  return EndTunnel

unchanneledMessageParser :: Parser Operation
unchanneledMessageParser = do
  word8 5
  _ <- take 9
  msg <- takeLazyByteString
  return $ UnchanneledMessage msg

--------------------------------------------------- END OF SERIALIZING/DESERIALIZING ---------------------------------------

-- Here we define our TunnelT monad transformer, along with some instances to ease the creation of typical monad stacks
-- This MonadTransformer is just like (ReaderT Tunnel)..
newtype TunnelT m a = TunnelT (ReaderT Tunnel m a)

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

instance (MonadIO m, MonadCatch m) => MonadCatch (TunnelT m) where
  catch (TunnelT action) handle = TunnelT $ catch action (\e -> let TunnelT vt = handle e in vt)

addConnection :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m ()
addConnection tc = getTunnel >>= addConnection' tc

addConnection' :: (MonadThrow m, MonadIO m) => TunnelConnection -> Tunnel -> m ()
addConnection' (TunnelConnection code) (Tunnel _ tvars) =
  liftIO $ atomically $ modifyTVar' tvars $ \(connSet, msgQueue, lastCode) -> (Set.insert code connSet, msgQueue, max code lastCode)

removeConnection' :: (MonadThrow m, MonadIO m) => TunnelConnection -> Tunnel -> m ()
removeConnection' (TunnelConnection code) (Tunnel _ tvars) =
  liftIO $ atomically $ modifyTVar' tvars $ \(connSet, msgQueue, lastCode) -> (Set.delete code connSet, msgQueue, max code lastCode)

addOpToQueue :: (MonadThrow m, MonadIO m) => Operation -> TunnelT m ()
addOpToQueue op = getTunnel >>= addOpToQueue' op

addOpToQueue' :: (MonadThrow m, MonadIO m) => Operation -> Tunnel -> m ()
addOpToQueue' op (Tunnel _ tvars) = liftIO $ atomically $ modifyTVar' tvars (\(connSet, msgqueue, lastCode) -> (connSet, msgqueue Seq.|> op, lastCode))

instance (MonadIO m, MonadBase b m) => MonadBase b (TunnelT m) where
  liftBase = liftBaseDefault

instance MonadTransControl TunnelT where
  type StT TunnelT a = StT (ReaderT Tunnel) a
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

-- | The Tunnel holds the Websocket connection, a set of open connection codes, the sequence of received operations in
-- the order in which they were received and the last connection code that was used.
data Tunnel = Tunnel !Connection !(TVar (Set.Set Word8, Seq.Seq Operation, Word8))

-- | Remove this in future versions of "container"
deleteAt :: Int -> Seq.Seq a -> Seq.Seq a
deleteAt idx s = Seq.take idx s Seq.>< Seq.drop (idx + 1) s

sendOp :: (MonadThrow m, MonadIO m) => Operation -> TunnelT m ()
sendOp op = getTunnel >>= sendOp' op

withTVar :: MonadIO m => TVar a -> (a -> b) -> m b
withTVar tv f = liftIO $ atomically $ do
  v <- readTVar tv
  return (f v)

-- ^ Waits for all open connections to end
waitForAllConnections :: (MonadThrow m, MonadIO m) => TunnelT m ()
waitForAllConnections = do
  Tunnel conn tvars <- getTunnel
  liftIO $ atomically $ do
    (connSet, _, _) <- readTVar tvars
    if Set.null connSet
      then return ()
      else retry

runTunnelT :: (MonadThrow m, MonadCatch m, MonadIO m) => TunnelT m a -> Connection -> m a
runTunnelT (TunnelT rm) conn = do
  tvars <- liftIO $ newTVarIO (Set.empty, Seq.empty, 0)
  let tun = Tunnel conn tvars
  forkAndForget $ receiveMessages tvars
  results <- runReaderT rm tun
  -- Send a close message and wait for the other close message as well
  --catch (liftIO $ sendClose conn ("" :: ByteString)) ignoreException
  return results
  where ignoreException :: Monad m => SomeException -> m ()
        ignoreException _ = return ()
        receiveMessages tvars = do
          excOrTunmod <- tryAny $ recvOp' conn
          case excOrTunmod of
            --Left e -> Prelude.putStrLn ("Exception receiving: " ++ show e) >> return ()
            Left _   -> return ()
            Right op -> do
              atomically $ modifyTVar' tvars (\(connSet, msgQueue, lastCode) -> (connSet, msgQueue Seq.|> op, lastCode))
              receiveMessages tvars
        waitForClose = do
          excOrMsg <- tryAny $ receive conn
          case excOrMsg of
            Right _ -> waitForClose
            --Left e -> print ("Finally: " ++ show e) >> return ()
            Left _  -> return ()

escapeTunnel :: (MonadThrow m, MonadIO m) => Tunnel -> TunnelT m a -> m a
escapeTunnel iot t = runReaderT rm iot
  where (TunnelT rm) = t

-- | Looks for the first received operation in the msgQueue that satisfies the predicate. 
-- If one isn't found, receives messages (while putting them in the queue) until it is found, removes it from the msgQueue and returns it.
recvUntil :: (MonadThrow m, MonadIO m) => (Operation -> Maybe (Maybe Operation, a)) -> TunnelT m a
recvUntil f = getTunnel >>= recvUntil' f

-- | Applies "f" to every received operation (in order of arrival) until it returns a tuple. Replaces
-- the Operation with the Operation in the tuple inside the message queue if an Operation is present,
-- finally returning the value from this function
recvUntil' :: (MonadThrow m, MonadIO m) => (Operation -> Maybe (Maybe Operation, a)) -> Tunnel -> m a
recvUntil' f tunnel@(Tunnel conn tvars) =
  liftIO $ atomically $ do
    vars <- readTVar tvars
    case getOpFromTunnel vars of
      (_, Nothing)                     -> retry
      (updatedValues, Just foundValue) -> do
        writeTVar tvars updatedValues
        return foundValue
  where findWithIdx :: (a -> Maybe b) -> Int -> [a] -> Maybe (a, b, Int)
        findWithIdx g i (x:xs) = case g x of
                                   Nothing -> findWithIdx g (i + 1) xs
                                   Just v  -> Just (x, v, i)
        findWithIdx _    _ []  = Nothing
        getOpFromTunnel (connSet, msgQueue, lastCode) =
          case findWithIdx f 0 (toList msgQueue) of
            Just (msg, (replacement, v), idx) ->
              let newQueue = case replacement of
                               Nothing -> deleteAt idx msgQueue
                               Just rp -> Seq.update idx rp msgQueue
              in ((connSet, newQueue, lastCode), Just v)
            Nothing -> ((connSet, msgQueue, lastCode), Nothing)

-- | Receives data from some tunnel connection (you can't pick which) and returns it
recvOp' :: (MonadThrow m, MonadIO m) => Connection -> m Operation
recvOp' conn = do
  dataMsg <- liftIO $ receiveDataMessage conn
  case dataMsg of
    Text _     -> throw ErrorWhenReceivingData
    Binary msg ->
      case parseOnly ((messageParser <|> connectionOpenedParser <|> socketClosedParser <|> unchanneledMessageParser <|> openConnectionParser <|> endTunnelParser) <* endOfInput) (toStrict msg) of
        Left er  -> throw ErrorWhenReceivingData
        Right op -> return op

openConnection :: (MonadThrow m, MonadIO m) => T.Text -> Int -> TunnelT m TunnelConnection
openConnection addr port = do
  sendOp (OpenConnection addr port)
  tc <- recvUntil isConnOpened
  addConnection tc
  return tc
  where isConnOpened op = case op of
                            ConnectionOpened code -> Just (Nothing, TunnelConnection code)
                            _                     -> Nothing

data ReceivedMessage = BytesOnly TunnelConnection ByteString | TunnelConnectionClosed TunnelConnection

recvDataFrom :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m ReceivedMessage
recvDataFrom tc = getTunnel >>= recvDataFrom' tc

recvDataFrom' :: (MonadThrow m, MonadIO m) => TunnelConnection -> Tunnel -> m ReceivedMessage
recvDataFrom' tc@(TunnelConnection connCode) tref = recvUntil' isDesired tref
  where isDesired (Message tc' bs)    = if tc' == connCode then Just (Nothing, BytesOnly tc bs) else Nothing
        isDesired (SocketClosed tc')  = if tc' == connCode then Just (Nothing, TunnelConnectionClosed tc) else Nothing
        isDesired _                   = Nothing

recvAtMostFrom :: (MonadThrow m, MonadIO m) => Int -> TunnelConnection -> TunnelT m ByteString
recvAtMostFrom size tc = getTunnel >>= recvAtMostFrom' size tc

recvAtMostFrom' :: (MonadThrow m, MonadIO m) => Int -> TunnelConnection -> Tunnel -> m ByteString
recvAtMostFrom' size tc@(TunnelConnection connCode) tref = recvUntil' isDesired tref
  where isDesired (Message tc' bs)
          | tc' /= connCode                        = Nothing
          | toInteger (length bs) > toInteger size = let (bytes, remaining) = splitAt (fromIntegral size) bs 
                                                     in Just (Just (Message tc' remaining), bytes)
          | otherwise                              = Just (Nothing, bs)
        isDesired _                                = Nothing

recvUnchanneledData :: (MonadThrow m, MonadIO m) => TunnelT m ByteString
recvUnchanneledData = recvUntil isUnchanneledMsg
  where isUnchanneledMsg op = case op of
                                UnchanneledMessage bs -> Just (Nothing, bs)
                                _                     -> Nothing

sendUnchanneledData :: (MonadThrow m, MonadIO m) => ByteString -> TunnelT m ()
sendUnchanneledData bs = sendOp $ UnchanneledMessage bs

sendData :: (MonadThrow m, MonadIO m) => ByteString -> TunnelConnection -> TunnelT m ()
sendData bs tc = getTunnel >>= sendData' bs tc

sendData' :: (MonadThrow m, MonadIO m) => ByteString -> TunnelConnection -> Tunnel -> m ()
sendData' msg (TunnelConnection code) tref = liftIO $ sendOp' (Message code msg) tref

closeConnection :: (MonadThrow m, MonadCatch m, MonadIO m) => TunnelConnection -> TunnelT m ()
closeConnection tc = getTunnel >>= closeConnection' tc

closeConnection' :: (MonadThrow m, MonadCatch m, MonadIO m) => TunnelConnection -> Tunnel -> m ()
closeConnection' (TunnelConnection code) tunnel@(Tunnel _ tvars) = do
  catchAny (sendOp' (SocketClosed code) tunnel) (const (return ()))
  liftIO $ atomically $ modifyTVar' tvars (\(connSet, msgQueue, lastCode) -> (Set.delete code connSet, msgQueue, lastCode))
  return ()

isTunnelOpen :: (MonadThrow m, MonadIO m) => TunnelConnection -> TunnelT m Bool
isTunnelOpen (TunnelConnection tc) = do
  Tunnel _ tvars <- getTunnel
  liftIO $ withTVar tvars (\(connSet, _, _) -> Set.member tc connSet)

getTunnel :: MonadIO m => TunnelT m Tunnel
getTunnel = TunnelT ask

forkAndForget :: MonadIO m => IO a -> m ()
forkAndForget action = do
    liftIO $ forkIO $ catchAny (action >> return ()) (const (return ()))
    return ()