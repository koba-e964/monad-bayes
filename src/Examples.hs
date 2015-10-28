{-# LANGUAGE
 TupleSections,
 FlexibleInstances,
 FlexibleContexts,
 DataKinds,
 TypeOperators,
 TypeFamilies
 #-}

module Examples where

import Base
import Dist
import Exact
import Explicit
import Sampler
import SMC
import MCMC

import qualified Data.Random.Distribution.Beta as Beta
import Data.Random.Distribution.Uniform (Uniform(Uniform))
import Data.Random.Distribution.Normal (Normal(Normal))
--import Data.Random.Distribution.Bernoulli (Bernoulli(Bernoulli))
import Data.Random.Distribution.Gamma (Gamma(Gamma))
import Data.Random.Distribution (pdf)

--import Numeric.LinearAlgebra.HMatrix
import Control.Monad (liftM, liftM2, mapM)
import Data.List (partition, nub)
import Data.Maybe (mapMaybe)
import Data.HList
import Data.Proxy

-----------------------------------------------------
--HMM

exampleHMM :: Dist [Int]
exampleHMM = liftM reverse states where
  states = foldl expand start values
  expand :: Dist [Int] -> Double -> Dist [Int]
  expand d y = condition (score y . head) $ do
    rest <- d
    x    <- trans $ head rest
    return (x:rest)
  score y x = prob $ pdf (Normal (fromIntegral x) 1) y
  trans (-1) = categorical $ zip [-1..1] [0.1, 0.4, 0.5]
  trans 0    = categorical $ zip [-1..1] [0.2, 0.6, 0.2]
  trans 1    = categorical $ zip [-1..1] [0.15,0.7,0.15]
  start   = uniformd [[-1], [0], [1]]
  values = [0.9,0.8,0.7,0,-0.025,5,2,0.1,0,
            0.13,0.45,6,0.2,0.3,-1,-1]

hmm :: (Functor d, Monad d) => d a -> (a -> d a) -> (a -> d b) -> d ([a],[b])
-- | A Hidden Markov Model defines a distribution over a pair of two lists:
-- a list of latent states and a list of observables.
-- Supports both finite and infinite cases.
hmm start trans gen =
 let
  construct x = fmap (x:) (trans x >>= construct)
 in
  do
    states      <- start >>= construct
    observables <- mapM gen states
    return (states, observables)

finiteHMM :: (Functor d, Monad d) => Int -> d a -> (a -> d a) -> (a -> d b) -> d ([a],[b])
-- | A Hidden Markov Model defines a distribution over a pair of two lists:
-- a list of latent states and a list of observables.
-- Finite list version.
finiteHMM n start trans gen =
 let
  construct 0 _ = return []
  construct n x = fmap (x:) (trans x >>= construct (n-1))
 in
  do
    states      <- start >>= construct n
    observables <- mapM gen states
    return (states, observables)

------------------------------------------------------------
--Dirichlet Processes

stick :: (Monad d, Bernoulli d) => [Prob] -> [a] -> d a
-- | Stick-breaking function.
stick (b:breaks) (a:atoms) =
    choice b (return a) (stick breaks atoms)

dp :: (Functor d, Monad d, Sampler d, Bernoulli d, Beta d) =>
        Double -> d a -> d (d a)
-- | A Dirichlet Process generates a random probability distribution
-- using the stick-breaking representation.
dp concentration base = do
  breaks <- sequence $ repeat $ fmap prob $ beta 1 concentration
  atoms  <- sequence $ repeat base
  return $ stick breaks atoms

dpData = [1.0,1.1,1.2,-1.0,-1.5,-2.0,0.001,0.01,0.005,0.0]

--dpData = [0.0,10.0]

dpMixture :: Dist [Int]
dpMixture =
  let
    --lazily generate clusters
    clusters = do
      let atoms = [1..]
      breaks <- sequence $ repeat $ fmap prob $ beta 1 1
      let classgen = stick breaks atoms
      vars <- sequence $ repeat $ fmap (1/) $ gamma 1 1
      means <- mapM (normal 0) vars
      return (classgen, vars, means)
    obs = [1.0,1.1,1.2,-1.0,-1.5,-2.0,
           0.001,0.01,0.005,0.0]
    n = length obs
    --start with no data points
    start = fmap (,[]) clusters

    --add points one by one
    points = foldl build start obs
    build d y = condition (score y . head . snd) $ do
      (clusters, rest) <- d
      let (classgen, vars, means) = clusters
      cluster <- classgen
      let point = (cluster, vars !! cluster,
                   means !! cluster)
      return (clusters, point : rest)

    --the likelihood in a cluster is Gaussian
    score y (cluster, var, mean) =
      -- Normal mean stddev
      prob $ pdf (Normal mean (sqrt var)) y

  in
   --exctract cluster assignments
   fmap (reverse . map (\(x,_,_) -> x) . snd) points

dpClusters = fmap (maximum . normalizePartition) dpMixture

normalizePartition :: [Int] -> [Int]
normalizePartition xs = mapMaybe (`lookup` trans) xs where
  trans = zip unique [1..]
  unique = nub xs

------------------------------------------------------------
--Coin tossing

coinToss :: (Functor d, Monad d, Conditional d, Beta d) => Double -> Double -> [Bool] -> d Prob
-- | An infinite sequence of coin tosses.
-- The prior on the coin weight is 'Beta' alpha beta.
coinToss a b results =
    register prior results where
        prior = fmap prob $ beta a b
        register d [] = d
        register d (r:rs) = register (observe d (bernoulli :: Prob -> Explicit Bool) r) rs

coinExact :: Prob -> Prob -> [Bool] -> Beta.Beta Prob
-- | Exact posterior for the 'coinToss' example.
coinExact alpha beta results =
    Beta.Beta (alpha + positive) (beta + negative) where
        (p,n) = partition id results
        positive = fromIntegral $ length p
        negative = fromIntegral $ length n

------------------------------------------------------------
--Die rolling

die :: (Monad d, UniformD n d, Integral n) => n -> d n
-- | A distribution over the sums of results of n independent rolls of a fair die
die 0 = return 0
die 1 = uniformd [1,2,3,4,5,6]
die n = liftM2 (+) (die 1) (die (n-1))

conditionalDie n = condition (\n -> 1 / fromIntegral n) (die n)

------------------------------------
--Linear regression

linear :: Dist (Double -> Double)
linear = do
  a <- normal 0 1
  b <- normal 0 1
  return (\x -> a*x + b)


------------------------------------
--JDist examples

type J = HList ('[Double,Double])

jbind1 :: (HSplitAt (HSucc HZero) zs xs ys, zs ~ HAppendListR xs ys, HAppendList xs ys) => JDist (HList xs) a -> (a -> JDist (HList ys) b) -> JDist (HList zs) b
jbind1 = JBind

sumg :: JDist J Double
sumg =
    normal 0 1 `jbind1` \x ->
    normal 0 1 `jbind1` \y ->
    JReturn (x+y)

sum_result :: Double
sum_result = eval sumg $ hBuild 1 2

sum_density :: Prob
sum_density = density sumg $ hBuild 1 2

sum_marginal :: Dist Double
sum_marginal = marginal sumg

sum_joint :: Dist (HList '[Double,Double])
sum_joint = joint sumg

sum_proposal :: JDist J J
sum_proposal =
    normal 0 2 `jbind1` \x ->
    normal 0 2 `jbind1` \y ->
    JReturn (hBuild x y)

sum_proposed :: JDist J Double
sum_proposed = propose sum_proposal sumg
