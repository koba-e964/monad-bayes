{-|
Module      : Control.Monad.Bayes.Weighted
Description : Probability monad accumulating the likelihood
Copyright   : (c) Adam Scibior, 2016
License     : MIT
Maintainer  : ams240@cam.ac.uk
Stability   : experimental
Portability : GHC

-}

{-# LANGUAGE
  GeneralizedNewtypeDeriving,
  TypeFamilies,
  StandaloneDeriving,
  FlexibleContexts,
  RankNTypes
 #-}

module Control.Monad.Bayes.Weighted (
    Weight,
    weight,
    unWeight,
    Weighted,
    withWeight,
    runWeighted,
    discardWeight,
    resetWeight,
    mapMonad,
    WeightRecorder,
    duplicateWeight,
    resetWeightRecorder,
    mapMonadWeightRecorder
                  ) where

import Control.Arrow (first,second)
import Data.Monoid
import Control.Monad.Trans.Class
import Control.Monad.Trans.State

import Control.Monad.Bayes.LogDomain
import Control.Monad.Bayes.Class

-- | Representation of a weight in importance sampling algorithms.
-- Internally represented in log-domain, but semantically a non-negative real number.
-- 'Monoid' instance with respect to multiplication.
newtype Weight r = Weight (Product (LogDomain r))
    deriving(Eq, Num, Ord, Show, Monoid)

-- | Semantic conversion.
weight :: LogDomain r -> Weight r
weight = Weight . Product

-- | Inverse of `weight`.
unWeight :: Weight r -> LogDomain r
unWeight (Weight (Product p)) = p

-- | Executes the program using the prior distribution, while accumulating likelihood.
newtype Weighted m a = Weighted {toStateT :: StateT (Weight (CustomReal m)) m a}
    deriving(Functor, Applicative, Monad)

type instance CustomReal (Weighted m) = CustomReal m

instance MonadTrans Weighted where
  lift = Weighted . lift

instance MonadDist m => MonadDist (Weighted m) where
  primitive = lift . primitive

instance MonadDist m => MonadBayes (Weighted m) where
  factor w = Weighted $ modify (* weight w)

-- | Obtain an explicit value of the likelihood for a given value.
runWeighted :: MonadDist m => Weighted m a -> m (a, LogDomain (CustomReal m))
runWeighted = fmap (second unWeight) . (`runStateT` 1) . toStateT

-- | Discards the weight.
discardWeight :: MonadDist m => Weighted m a -> m a
discardWeight = fmap fst . runWeighted

-- | Embed a random variable with explicitly given likelihood.
--
-- > runWeighted . withWeight = id
withWeight :: MonadDist m => m (a, LogDomain (CustomReal m)) -> Weighted m a
withWeight m = Weighted $ do
  (x,w) <- lift m
  put $ weight w
  return x

-- | Reset weight to 1.
resetWeight :: MonadDist m => Weighted m a -> Weighted m a
resetWeight (Weighted m) = Weighted $ m >>= \x -> put 1 >> return x

-- | Apply a transformation to the transformed monad.
mapMonad :: MonadDist m => (forall a. m a -> m a) -> Weighted m a -> Weighted m a
mapMonad t = Weighted . mapStateT t . toStateT

-- | Similar to 'Weighted', only each factor is both  passed to the transformed
-- monad and its value is accumulated in a weight.
-- Useful for getting the likelihood of samples from the posterior.
newtype WeightRecorder m a =
  WeightRecorder {runWeightRecorder :: Weighted m a}
    deriving(Functor, Applicative, Monad, MonadTrans)
type instance CustomReal (WeightRecorder m) = CustomReal m
deriving instance MonadDist m => MonadDist (WeightRecorder m)

instance MonadBayes m => MonadBayes (WeightRecorder m) where
  factor w = WeightRecorder (factor w >> lift (factor w))

-- | Stop passing factors to the transformed monad.
duplicateWeight :: WeightRecorder m a -> Weighted m a
duplicateWeight = runWeightRecorder

-- | Reset weight record to 1, not modifying the transformed monad.
resetWeightRecorder :: MonadDist m => WeightRecorder m a -> WeightRecorder m a
resetWeightRecorder = WeightRecorder . resetWeight . runWeightRecorder

-- | Apply a transformation to the transformed monad.
mapMonadWeightRecorder :: MonadDist m => (forall a. m a -> m a) -> WeightRecorder m a -> WeightRecorder m a
mapMonadWeightRecorder t = WeightRecorder . mapMonad t . runWeightRecorder
