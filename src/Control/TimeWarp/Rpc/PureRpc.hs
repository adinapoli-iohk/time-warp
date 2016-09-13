{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Control.TimeWarp.Rpc.PureRpc
       ( PureRpc
       , runPureRpc
       , runPureRpc_
       , Delays (..)
       ) where

import           Control.Lens                  (makeLenses, use, (%%=), (%=))
import           Control.Monad                 (forM_)
import           Control.Monad.Catch           (MonadCatch, MonadMask,
                                                MonadThrow, throwM)
import           Control.Monad.Random          (Rand, runRand)
import           Control.Monad.State           (MonadState (get, put, state),
                                                StateT, evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (Default, def)
import           Data.Map                      as Map
import           System.Random                 (StdGen)

import           Data.MessagePack              (Object)
import           Data.MessagePack.Object       (MessagePack, fromObject,
                                                toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (Client (..), Host, Method (..),
                                                MonadRpc (execClient, serve),
                                                NetworkAddress, RpcError (..),
                                                methodBody, methodName)
import           Control.TimeWarp.Timed        (Microsecond, MonadTimed (..),
                                                TimedT, evalTimedT, for, mcs,
                                                localTime, minute, runTimedT,
                                                wait, PureThreadId)

localhost :: Host
localhost = "127.0.0.1"

-- | List of known issues:
--     -) Method, once being declared in net, can't be removed
--        Even timeout won't help
--        Status: not relevant in tests for now
--     -) Connection can't be refused, only be held on much time
--        Status: not relevant until used with fixed timeout

data RpcStage = Request | Response

-- @TODO Remove these hard-coded values
-- | Describes network nastyness.
--
-- Examples:
--
-- * Always 1 second delay:
--
-- @
-- Delays $ \\_ _ -> return $ Just (interval 1 sec)
-- @
--
-- * Delay changes between 1 and 5 seconds (with granularity of 1 mcs):
--
-- @
-- Delays $ \\_ _ -> do
--     delay <- fromMicroseconds $ getRandomR $ both %~ toMicroseconds $ (interval 1 sec :: Microsecond, interval 5 sec)
--     return $ Just delay
-- @
--
-- * Connection established with probability of 1/6:
--
-- @
-- Delays $ \\_ time -> do
--     p <- getRandomR (0, 5)
--     if p == 0
--         then return $ Just 0
--         else return Nothing
-- @
newtype Delays = Delays
    { -- | Basing on current virtual time, returns `Just` delay,
      -- if connection should be considered as successfully established,
      -- and `Nothing` otherwise.
      evalDelay :: RpcStage
                -> Microsecond
                -> Rand StdGen (Maybe Microsecond)
    }

-- This is needed for QC
instance Show Delays where
    show _ = "Delays"

-- | Descirbes reliable network
instance Default Delays where
    def = Delays . const . const . return . Just $ 0

-- | Keeps servers' methods
type Listeners m = Map.Map (NetworkAddress, String) ([Object] -> m Object)

-- | Keeps global network information
data NetInfo m = NetInfo
    { _listeners :: Listeners m
    , _randSeed  :: StdGen
    , _delays    :: Delays
    }

$(makeLenses ''NetInfo)

-- | Pure implementation of RPC
newtype PureRpc m a = PureRpc
    { unwrapPureRpc :: StateT Host (TimedT (StateT (NetInfo (PureRpc m)) m)) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch,
                MonadMask)

instance (MonadIO m, MonadCatch m, WithNamedLogger m) =>
         MonadTimed (PureRpc m) where
    type ThreadId (PureRpc m) = PureThreadId

    localTime = PureRpc localTime

    wait = PureRpc . wait

    fork = PureRpc . fork . unwrapPureRpc

    myThreadId = PureRpc myThreadId

    throwTo tid = PureRpc . throwTo tid

    timeout t = PureRpc . timeout t . unwrapPureRpc

instance MonadTrans PureRpc where
    lift = PureRpc . lift . lift . lift

instance MonadState s m => MonadState s (PureRpc m) where
    get = lift get
    put = lift . put
    state = lift . state

-- | Launches rpc scenario.
runPureRpc
    :: (MonadIO m, MonadCatch m)
    => StdGen -> Delays -> PureRpc m a -> m a
runPureRpc _randSeed _delays (PureRpc rpc) =
    evalStateT (evalTimedT (evalStateT rpc localhost)) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

-- | Launches rpc scenario without result. May be slightly more efficient.
runPureRpc_
    :: (MonadIO m, MonadCatch m)
    => StdGen -> Delays -> PureRpc m () -> m ()
runPureRpc_ _randSeed _delays (PureRpc rpc) =
    evalStateT (runTimedT (evalStateT rpc localhost)) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

-- TODO: use normal exceptions here
request :: (Monad m, MonadThrow m, MessagePack a)
        => Client a
        -> (Listeners (PureRpc m), NetworkAddress)
        -> PureRpc m a
request (Client name args) (listeners', addr) =
    case Map.lookup (addr, name) listeners' of
        Nothing -> throwM $ ServerError $ toObject $ mconcat
            ["method \"", name, "\" not found at adress ", show addr]
        Just f  -> do
            res <- f args
            case fromObject res of
                Nothing -> throwM $ ResultTypeError "type mismatch"
                Just r  -> return r


instance (WithNamedLogger m, MonadIO m, MonadThrow m, MonadCatch m) =>
         MonadRpc (PureRpc m) where
    execClient addr cli =
        PureRpc $
        do curHost <- get
           unwrapPureRpc $ waitDelay Request
           ls <- lift . lift $ use listeners
           put $ fst addr
           answer <- unwrapPureRpc $ request cli (ls, addr)
           unwrapPureRpc $ waitDelay Response
           put curHost
           return answer
    serve port methods =
        PureRpc $
        do host <- get
           lift $
               lift $
               forM_ methods $
               \Method {..} ->
                    listeners %=
                    Map.insert ((host, port), methodName) methodBody
           sleepForever
      where
        sleepForever = wait (for 100500 minute) >> sleepForever

waitDelay
    :: (WithNamedLogger m, MonadThrow m, MonadIO m, MonadCatch m)
    => RpcStage -> PureRpc m ()
waitDelay stage =
    PureRpc $
    do delays' <- lift . lift $ use delays
       time <- localTime
       delay <- lift . lift $ randSeed %%= runRand (evalDelay delays' stage time)
       wait $ maybe (for 99999 minute) (`for` mcs) delay
