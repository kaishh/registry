{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE IncoherentInstances   #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE UndecidableInstances  #-}
{- |

  RIO is equivalent to @ResourceT (WriterT Warmup IO)@
  It can be used to instantiate "modules as records of functions"
  where each module can allocate resources and have a "warmup phase"
  to preload data or asses if it is working properly

-}
module Data.Registry.RIO where

import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Trans.Resource
import qualified Control.Monad.Trans.Resource as Resource (allocate)

import           Data.Registry.Make
import           Data.Registry.Registry
import           Data.Registry.Solver
import           Data.Registry.Warmup
import           Protolude

-- | Data type encapsulating resource finalizers
newtype Stop = Stop InternalState

-- | Run all finalizers
runStop :: Stop -> IO ()
runStop (Stop is) = runResourceT $ closeInternalState is

-- | This newtype creates a monad to sequence
--   module creation actions, cumulating start/stop tasks
--   found along the way
newtype RIO a =
  RIO
  { runRIO :: Stop -> IO (a, Warmup) }
  deriving (Functor)

instance Applicative RIO where
  pure a =
    RIO (const (pure (a, mempty)))

  RIO fab <*> RIO fa =
    RIO $ \s ->
      do (f, sf) <- fab s
         (a, sa) <- fa s
         pure (f a, sf `mappend` sa)

instance Monad RIO where
  return = pure

  RIO ma >>= f =
    RIO $ \s ->
      do (a, sa) <- ma s
         (b, sb) <- runRIO (f a) s
         pure (b, sa `mappend` sb)

instance MonadIO RIO where
  liftIO io = RIO (const $ (, mempty) <$> io)

instance MonadThrow RIO where
  throwM e = RIO (const $ throwM e)

instance MonadBase IO RIO where
  liftBase = liftIO

instance MonadResource RIO where
  liftResourceT action = RIO $ \(Stop s) -> liftIO ((, mempty) <$> runInternalState action s)

-- * For production

-- | This function must be used to run services involving a top module
--   It creates the top module and invokes all warmup functions
--
--   The passed function 'f' is used to decide whether to continue or
--   not depending on the Result
withRegistry :: forall a b ins out . (Typeable a, Contains (RIO a) out, Solvable ins out) =>
     Registry ins out
  -> (Result -> a -> IO b)
  -> IO b
withRegistry registry f = runResourceT $ do
  (a, warmup) <- runRegistryT @a registry
  result      <- lift $ runWarmup warmup
  lift $ f result a

-- | This can be used if you want to insert the component creation inside
--   another action managed with 'ResourceT'. Or if you want to call 'runResourceT' yourself later
runRegistryT :: forall a ins out . (Typeable a, Contains (RIO a) out, Solvable ins out) => Registry ins out -> ResourceT IO (a, Warmup)
runRegistryT registry = withInternalState $ \is -> runRIO (make @(RIO a) registry) (Stop is)

-- * For testing

-- | Instantiate the component but don't execute the warmup (it may take time)
--   and keep the Stop value to clean resources later
--   This function statically checks that the component can be instantiated
executeRegistry :: forall a ins out . (Typeable a, Contains (RIO a) out, Solvable ins out) => Registry ins out -> IO (a, Warmup, Stop)
executeRegistry registry = do
  is <- createInternalState
  (a, w) <- runRIO (make @(RIO a) registry) (Stop is)
  pure (a, w, Stop is)

-- | Instantiate the component but don't execute the warmup (it may take time) and lose a way to cleanu up resources
-- | Almost no compilation time is spent on checking that component resolution is possible
unsafeRun :: forall a ins out . (Typeable a, Contains (RIO a) out) => Registry ins out -> IO a
unsafeRun registry = fst <$> unsafeRunWithStop registry

-- | Same as 'unsafeRun' but keep the 'Stop' value to be able to clean resources later
unsafeRunWithStop :: forall a ins out . (Typeable a, Contains (RIO a) out) => Registry ins out -> IO (a, Stop)
unsafeRunWithStop registry = do
  is <- createInternalState
  (a, _) <- runRIO (makeUnsafe @(RIO a) registry) (Stop is)
  pure (a, Stop is)

-- | Lift a 'Warmup' action into the 'RIO' monad
warmupWith :: Warmup -> RIO ()
warmupWith w = RIO (const $ pure ((), w))

-- | Allocate some resource
allocate :: IO a -> (a -> IO ()) -> RIO a
allocate resource cleanup =
  snd <$> Resource.allocate resource cleanup
