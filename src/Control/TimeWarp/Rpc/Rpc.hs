{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Rpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines default instance of `MonadRpc`.

module Control.TimeWarp.Rpc.Rpc
       ( Rpc (..)
       , runRpc
       ) where

import           Control.Concurrent.MVar           (MVar, newEmptyMVar, takeMVar,
                                                    putMVar)
import           Control.Concurrent.STM            (STM, atomically)
import           Control.Concurrent.STM.TVar       (TVar, newTVarIO, readTVar,
                                                    writeTVar)
import           Control.Lens                      (makeLenses, (<<+=), at, (?=), (.=),
                                                    use)
import           Control.Monad.Catch               (MonadThrow, MonadCatch, MonadMask,
                                                    bracket)
import           Control.Monad                     (forM_)
import           Control.Monad.Reader              (ReaderT (..), ask)
import           Control.Monad.State               (MonadState, StateT, runStateT)
import           Control.Monad.Trans               (MonadTrans (..), MonadIO (..))
import           Data.Binary                       (Get, get, put)
import           Data.Dynamic                      (Dynamic, toDyn, fromDyn)
import qualified Data.Map                          as M

import           Control.TimeWarp.Logging          (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadDialog  (MonadDialog (..), ResponseT (..),
                                                    ListenerH (..),
                                                    listenH, replyH, sendH,
                                                    listenOutboundH)
import           Control.TimeWarp.Rpc.MonadRpc      (MonadRpc (..), Request (..),
                                                     Method (..))
import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer)
import           Control.TimeWarp.Timed.MonadTimed  (MonadTimed, ThreadId, fork_)


-- * Related datatypes

type MsgId = Int

data Manager = Manager
    { _msgCounter :: MsgId
    , _msgSlots   :: M.Map MsgId (MVar Dynamic)
    }
$(makeLenses ''Manager)

initManager :: Manager
initManager =
    Manager
    { _msgCounter = 0
    , _msgSlots   = M.empty
    }

-- * Default instance of `MonadRpc`

newtype Rpc m a = Rpc
    { getRpc :: ReaderT (TVar Manager) m a
    } deriving (Functor, Applicative, Monad, MonadIO,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer, MonadDialog)

runRpc :: MonadIO m => Rpc m a -> m a
runRpc rpc = liftIO (newTVarIO initManager) >>= runReaderT (getRpc rpc)

type instance ThreadId (Rpc m) = ThreadId m

modifyManager :: MonadIO m => StateT Manager STM a -> Rpc m a
modifyManager how = Rpc $ do
    t <- ask
    liftIO . atomically $ do
        s <- readTVar t
        (a, s') <- runStateT how s
        writeTVar t s'
        return a

instance (MonadTimed m, MonadDialog m, MonadIO m, MonadMask m)
       => MonadRpc (Rpc m) where
    call addr req = do
        -- make slot for response
        slot <- liftIO newEmptyMVar
        fork_ $ listenIncoming
        bracket (allocateRespSlot slot)
                (\msgid -> modifyManager $ msgSlots . at msgid .= Nothing) $
                 \msgid -> do
                    -- send
                    sendH addr (put msgid) req
                    -- process answer
                    resp <- liftIO $ takeMVar slot
                    return $ fromDyn resp typeMismatchError
      where
        allocateRespSlot slot = modifyManager $ do
            msgid <- msgCounter <<+= 1
            msgSlots . at msgid ?= slot
            return msgid

        listenIncoming = listenOutboundH addr (get :: Get MsgId)
            [ ListenerH $ \(msgid, resp) -> lift $ do
                maybeSlot <- modifyManager $ use $ msgSlots . at msgid
                liftIO . forM_ maybeSlot $ 
                    flip putMVar $ toDyn $ restrictType req resp
            ]
        restrictType :: 
                     r -> Response r -> Response r
        restrictType = const id
        typeMismatchError = error "Type mismatch! Probably msgid duplicate"

    serve port methods = listenH port (get :: Get MsgId) $ convert <$> methods
      where
        convert (Method f) = ListenerH $
            \(msgid, req) -> f req >>= replyH (put msgid)

