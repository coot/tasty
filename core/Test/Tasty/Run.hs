-- | Running tests
{-# LANGUAGE ScopedTypeVariables, ExistentialQuantification #-}
module Test.Tasty.Run
  ( Status(..)
  , StatusMap
  , launchTestTree
  ) where

import qualified Data.IntMap as IntMap
import qualified Data.Sequence as Seq
import qualified Data.Foldable as F
import Data.Maybe
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Timeout
import Control.Concurrent.Async
import Control.Exception
import Control.Applicative
import Control.Arrow

import Test.Tasty.Core
import Test.Tasty.Parallel
import Test.Tasty.Options
import Test.Tasty.CoreOptions
import Test.Tasty.Runners.Reducers

-- | Current status of a test
data Status
  = NotStarted
    -- ^ test has not started running yet
  | Executing Progress
    -- ^ test threw an exception and was aborted
  | Done Result
    -- ^ test finished with a given result

-- | Mapping from test numbers (starting from 0) to their status variables.
--
-- This is what an ingredient uses to analyse and display progress, and to
-- detect when tests finish.
type StatusMap = IntMap.IntMap (TVar Status)

data Resource r
  = NotCreated
  | FailedToCreate SomeException
  | Created r

data Initializer
  = forall res . Initializer
      (IO res)
      (MVar (Resource res))
data Finalizer
  = forall res . Finalizer
      (res -> IO ())
      (MVar (Resource res))
      (MVar Int)

-- | Execute a test taking care of resources
executeTest
  :: ((Progress -> IO ()) -> IO Result)
    -- ^ the action to execute the test, which takes a progress callback as
    -- a parameter
  -> TVar Status -- ^ variable to write status to
  -> Timeout -- ^ optional timeout to apply
  -> Seq.Seq Initializer -- ^ initializers (to be executed in this order)
  -> Seq.Seq Finalizer -- ^ finalizers (to be executed in this order)
  -> IO ()
executeTest action statusVar timeoutOpt inits fins =
  handle (atomically . writeTVar statusVar . Done . exceptionResult) $ do
  -- We don't try to protect against async exceptions here.
  -- This is because we use interruptible modifyMVar and wouldn't be able
  -- to give any guarantees anyway.
  -- So all we do is guard actual acquire/test/release actions using 'try'.
  -- The only thing we guarantee upon catching an async exception is that
  -- we'll write it to the status var, so that the UI won't be waiting
  -- infinitely.
  resultOrExcn <- runEitherT $ do
    F.forM_ inits $ \(Initializer doInit initVar) -> EitherT $
      modifyMVar initVar $ \resStatus  ->
        case resStatus of
          NotCreated -> do
            mbRes <- try doInit
            case mbRes of
              Right res -> return (Created res, Right ())
              Left ex -> return (FailedToCreate ex, Left ex)
          Created {} -> return (resStatus, Right ())
          FailedToCreate ex -> return (resStatus, Left ex)

    -- if all initializers ran successfully, actually run the test
    let
      applyTimeout NoTimeout a = a
      applyTimeout (Timeout t tstr) a = do
        let
          timeoutResult = Right $
            Result
              { resultFailure = Just $ TestTimedOut t
              , resultDescription =
                  "Timed out after " ++ tstr
              }
        fromMaybe timeoutResult <$> timeout t a

    EitherT $
      withAsync (action yieldProgress) $ \asy ->
        applyTimeout timeoutOpt $
          waitCatch asy

  -- no matter what, try to run each finalizer
  -- remember the first exception that occurred
  mbExcn <- liftM getFirst . execWriterT . getTraversal $
    flip F.foldMap fins $ \(Finalizer doRelease initVar finishVar) ->
      Traversal $ do
        mbExcn <-
          liftIO $ modifyMVar finishVar $ \nUsers -> do
            let nUsers' = nUsers - 1
            mbExcn <-
              if nUsers' == 0
              then do
                resStatus <- readMVar initVar
                case resStatus of
                  Created res ->
                    either
                      (\ex -> Just ex)
                      (\_ -> Nothing)
                    <$> try (doRelease res)
                  _ -> return Nothing
              else return Nothing
            return (nUsers', mbExcn) -- end of modifyMVar

        tell $ First mbExcn

  atomically . writeTVar statusVar $ Done $
    case resultOrExcn <* maybe (return ()) Left mbExcn of
      Left ex -> exceptionResult ex
      Right r -> r

  where
    -- The callback
    -- Since this is not used yet anyway, disable for now.
    -- I'm not sure whether we should get rid of this altogether. For most
    -- providers this is either difficult to implement or doesn't make
    -- sense at all.
    -- See also https://github.com/feuerbach/tasty/issues/33
    yieldProgress _ = return ()

type InitFinPair = (Seq.Seq Initializer, Seq.Seq Finalizer)

-- | Turn a test tree into a list of actions to run tests coupled with
-- variables to watch them
createTestActions :: OptionSet -> TestTree -> IO [(IO (), TVar Status)]
createTestActions opts tree =
  liftM (map (first ($ (Seq.empty, Seq.empty)))) $
  execWriterT $ getTraversal $
  (foldTestTree
    trivialFold
      { foldSingle = runSingleTest
      , foldResource = addInitAndRelease
      }
    opts
    tree
    :: Traversal (WriterT [(InitFinPair -> IO (), TVar Status)] IO))
  where
    runSingleTest opts _ test = Traversal $ do
      statusVar <- liftIO $ atomically $ newTVar NotStarted
      let
        act (inits, fins) =
          executeTest (run opts test) statusVar (lookupOption opts) inits fins
      tell [(act, statusVar)]
    addInitAndRelease (ResourceSpec doInit doRelease) a =
      Traversal . WriterT . fmap ((,) ()) $ do
        initVar <- newMVar NotCreated
        tests <- execWriterT $ getTraversal $ a (getResource initVar)
        let ntests = length tests
        finishVar <- newMVar ntests
        let
          ini = Initializer doInit initVar
          fin = Finalizer doRelease initVar finishVar
        return $ map (first $ local $ (Seq.|> ini) *** (fin Seq.<|)) tests

-- | Used to create the IO action which is passed in a WithResource node
getResource :: MVar (Resource r) -> IO r
getResource var =
  readMVar var >>= \rState ->
    case rState of
      Created r -> return r
      NotCreated -> throwIO $ UnexpectedState "not created"
      FailedToCreate {} -> throwIO $ UnexpectedState "failed to create"

-- | Start running all the tests in a test tree in parallel. The number of
-- threads is determined by the 'NumThreads' option.
--
-- Return a map from the test number (starting from 0) to its status
-- variable.
launchTestTree :: OptionSet -> TestTree -> IO StatusMap
launchTestTree opts tree = do
  testActions <- createTestActions opts tree
  let NumThreads numTheads = lookupOption opts
  runInParallel numTheads (fst <$> testActions)
  return $ IntMap.fromList $ zip [0..] (snd <$> testActions)

-- EitherT from the 'either' package
{- License for the 'either' package

Copyright 2008-2011 Edward Kmett

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

3. Neither the name of the author nor the names of his contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
-}

newtype EitherT e m a = EitherT { runEitherT :: m (Either e a) }


instance Monad m => Functor (EitherT e m) where
  fmap f = EitherT . liftM (fmap f) . runEitherT

instance Monad m => Applicative (EitherT e m) where
  pure a  = EitherT $ return (Right a)
  EitherT f <*> EitherT v = EitherT $ f >>= \mf -> case mf of
    Left  e -> return (Left e)
    Right k -> v >>= \mv -> case mv of
      Left  e -> return (Left e)
      Right x -> return (Right (k x))

instance (Monad m, Monoid e) => Alternative (EitherT e m) where
  EitherT m <|> EitherT n = EitherT $ m >>= \a -> case a of
    Left l -> liftM (\b -> case b of
      Left l' -> Left (mappend l l')
      Right r -> Right r) n
    Right r -> return (Right r)
  empty = EitherT $ return (Left mempty)

instance Monad m => Monad (EitherT e m) where
  return a = EitherT $ return (Right a)
  m >>= k  = EitherT $ do
    a <- runEitherT m
    case a of
      Left  l -> return (Left l)
      Right r -> runEitherT (k r)
  fail = EitherT . fail

instance (Monad m, Monoid e) => MonadPlus (EitherT e m) where
  mplus = (<|>)
  mzero = empty
