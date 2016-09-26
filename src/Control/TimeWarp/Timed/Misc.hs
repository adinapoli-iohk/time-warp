-- | `MonadTimed` related helper functions.

module Control.TimeWarp.Timed.Misc
       ( repeatForever
       , sleepForever
       ) where

import           Control.Concurrent.STM.TVar       (newTVarIO, readTVarIO, writeTVar)
import           Control.Exception.Base            (SomeException)
import           Control.Monad                     (forever)
import           Control.Monad.Catch               (MonadCatch, catch)
import           Control.Monad.STM                 (atomically)
import           Control.Monad.Trans               (MonadIO, liftIO)

import           Control.TimeWarp.Timed.MonadTimed (Microsecond, MonadTimed, for, fork_,
                                                    minute, ms, startTimer, wait)

-- | Repeats an action periodically.
--   If it fails, handler is invoked, determining delay before retrying.
--   Can be interrupted with asynchronous exception.
repeatForever
    :: (MonadTimed m, MonadIO m, MonadCatch m)
    => Microsecond                      -- ^ Period between action launches
    -> (SomeException -> m Microsecond) -- ^ What to do on exception,
                                        --   returns delay before retrying
    -> m ()                             -- ^ Action
    -> m ()
repeatForever period handler action = do
    timer <- startTimer
    nextDelay <- liftIO $ newTVarIO Nothing
    fork_ $
        let setNextDelay = liftIO . atomically . writeTVar nextDelay . Just
            action' =
                action >> timer >>= \passed -> setNextDelay (period - passed)
            handler' e = handler e >>= setNextDelay
        in action' `catch` handler'
    waitForRes nextDelay
  where
    continue = repeatForever period handler action
    waitForRes nextDelay = do
        wait $ for 10 ms
        res <- liftIO $ readTVarIO nextDelay
        case res of
            Nothing -> waitForRes nextDelay
            Just t  -> wait (for t) >> continue

-- | Sleep forever.

-- TODO: would be better to use `MVar` to block thread
sleepForever :: MonadTimed m => m ()
sleepForever = forever $ wait (for 100500 minute)
