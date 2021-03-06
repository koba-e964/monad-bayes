{-|
Module      : Control.Monad.Bayes.Dist
Description : Exact representation of distributions with finite support
Copyright   : (c) Adam Scibior, 2016
License     : MIT
Maintainer  : ams240@cam.ac.uk
Stability   : experimental
Portability : GHC

-}

module Control.Monad.Bayes.Dist (
    Enumerator,
    toPopulation,
    hoist,
    Dist,
    toList,
    explicit,
    evidence,
    mass,
    compact,
    enumerate,
    expectation
            ) where

import Control.Applicative (Applicative, pure)
import Control.Arrow (second)
import qualified Data.Map as Map
import Control.Monad.Trans
import Data.Maybe (fromMaybe)

import Control.Monad.Bayes.LogDomain (LogDomain, fromLogDomain, toLogDomain, NumSpec)
import Control.Monad.Bayes.Class
import qualified Control.Monad.Bayes.Population as Pop
import Control.Monad.Bayes.Deterministic


-- | A transformer similar to 'Population', but additionally integrates
-- discrete random variables by enumerating all execution paths.
newtype Enumerator m a = Enumerator {runEnumerator :: Pop.Population m a}
  deriving(Functor, Applicative, Monad, MonadTrans)

type instance CustomReal (Enumerator m) = CustomReal m

instance MonadDist m => MonadDist (Enumerator m) where
  discrete ps = Enumerator $ Pop.fromWeightedList $ pure $ map (second toLogDomain) $ normalize $ zip [0..] ps
  normal  m s = lift $ normal  m s
  gamma   a b = lift $ gamma   a b
  beta    a b = lift $ beta    a b
  uniform a b = lift $ uniform a b

instance MonadDist m => MonadBayes (Enumerator m) where
  factor w = Enumerator $ factor w

-- | Convert 'Enumerator' to 'Population'.
toPopulation :: Enumerator m a -> Pop.Population m a
toPopulation = runEnumerator

-- | Apply a transformation to the inner monad.
hoist :: (MonadDist m, MonadDist n, CustomReal m ~ CustomReal n) =>
  (forall x. m x -> n x) -> Enumerator m a -> Enumerator n a
hoist f = Enumerator . Pop.hoist f . toPopulation

-- | A monad for discrete distributions enumerating all possible paths.
-- Throws an error if a continuous distribution is used.
type Dist r a = Enumerator (Deterministic r) a

-- | Throws an error if continuous random variables were used in 'Dist'.
ensureDiscrete :: Deterministic r a -> a
ensureDiscrete =
  fromMaybe (error "Dist: there were unhandled continuous random variables") .
  maybeDeterministic

-- | Returns the posterior as a list of weight-value pairs without any post-processing,
-- such as normalization or aggregation
toList :: (Real r, NumSpec r) => Dist r a -> [(a, LogDomain r)]
toList = ensureDiscrete . Pop.runPopulation . toPopulation

-- | Same as `toList`, only weights are converted from log-domain.
explicit :: (Real r, NumSpec r) => Dist r a -> [(a,r)]
explicit = map (second fromLogDomain) . toList

-- | Returns the model evidence, that is sum of all weights.
evidence :: (Real r, NumSpec r) => Dist r a -> LogDomain r
evidence = ensureDiscrete . Pop.evidence . toPopulation

-- | Normalized probability mass of a specific value.
mass :: (Real r, NumSpec r, Ord a) => Dist r a -> a -> r
mass d = f where
  f a = case lookup a m of
             Just p -> p
             Nothing -> 0
  m = normalize (enumerate d)

-- | Aggregate weights of equal values.
-- The resulting list is sorted ascendingly according to values.
compact :: (Num r, Ord a) => [(a,r)] -> [(a,r)]
compact = Map.toAscList . Map.fromListWith (+)

-- | Normalize the weights to sum to 1.
normalize :: Fractional p => [(a,p)] -> [(a,p)]
normalize xs = map (second (/ z)) xs where
  z = sum $ map snd xs

-- | Aggregate and normalize of weights.
-- The resulting list is sorted ascendingly according to values.
--
-- > enumerate = compact . explicit
enumerate :: (Real r, NumSpec r, Ord a) => Dist r a -> [(a,r)]
enumerate = compact . explicit

-- | Expectation of a given function computed using unnormalized weights.
expectation :: (Real r, NumSpec r) => (a -> r) -> Dist r a -> r
expectation f = ensureDiscrete . Pop.popAvg f . toPopulation
