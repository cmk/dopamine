{-# LANGUAGE DeriveGeneric, 
             MultiParamTypeClasses, 
             FlexibleInstances,
             FlexibleContexts, 
             GeneralizedNewtypeDeriving,
             FunctionalDependencies, 
             UndecidableInstances, 
             TypeSynonymInstances,
             TypeFamilies 
#-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main where

import Control.Exception.Safe (assert, MonadThrow)
import Control.Monad
import Control.Monad.Loops
import Control.Monad.Morph (MFunctor(..), MMonad(..), generalize)
import Control.Monad.IO.Class
import Control.Monad.Primitive
import Control.Monad.RWS.Class
import Control.Monad.Trans.Reader (ReaderT(..))
import Control.Monad.Trans.RWS (RWST, evalRWST)
import Data.List (maximumBy, sort)
import Data.Ord (comparing)
import Data.Vector ((!), Vector)
import Data.IORef

import qualified Control.Monad.Trans.Reader as TR
import qualified Data.DList as D
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import qualified Statistics.Distribution as Dist
import qualified Statistics.Distribution.Normal as N
import qualified System.Random.MWC as R

import Numeric.Dopamine.Environment hiding (stepEnv)
import qualified Numeric.Dopamine.Outcome as O

main :: IO ()
main = print "hi"

{-
newtype Environment a = 
  Environment { getEnvironment :: RWST (IORef BanditState) (D.DList Outcome) EnvState IO a }
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadThrow
    , MonadReader (IORef BanditState)
    , MonadWriter (D.DList Outcome)
    , MonadState EnvState
    , MonadRWS (IORef BanditState) (D.DList Outcome) EnvState
    )

instance PrimMonad Environment where
  type PrimState Environment = RealWorld
  primitive = Environment . primitive

-- | The slot machine index whose arm will be pulled
type Action = Int
type Reward = Double
type Outcome = O.Outcome Action Double

--type BanditEnv = EnvT Outcome (ReaderT EnvState IO)
type BanditEnv = EnvT Outcome Environment

-- | Default config of a n-armed bandit
envState :: Int -> IO EnvState
envState n = mkEnvState n $ replicate n 1.0

banditState :: Int -> Stats -> IO (IORef BanditState)
banditState n s = do
  r <- newIORef mempty
  let init = Map.fromList $ take n $ zip [0..] (repeat s)
  writeIORef r init
  return r

defaultBanditState :: Int -> IO (IORef BanditState)
defaultBanditState n = banditState n mempty

mkEnvState :: Int -> [Double] -> IO EnvState
mkEnvState n vars = do
  gen <- R.createSystemRandom
  means <- replicateM n $ R.uniform gen
  let arms = V.fromList $ zipWith N.normalDistr (reverse $ sort means) vars
  return $ EnvState arms gen 0

episodeLength :: Int
episodeLength = 100

narms :: Int
narms = 10

main :: IO ()
main = do
  casino <- envState narms
  bandit <- defaultBanditState narms
  -- bandit <- banditState narms (Stats 0 10.0) -- TODO randomize in case of ties

  res <- runEnvironment bandit casino act1
  mapM_ print $ D.toList res

{-
askEnv :: (MonadEnv EnvState Outcome m e) => e m Outcome
askEnv = view $ \s -> 
  if pulls s <= episodeLength then Just $ O.Outcome 0 0 else Nothing

-- whileJust_ :: Monad m => m (Maybe a) -> (a -> m b) -> m ()
--

config stepEnv'
  :: MonadEnv s Outcome Environment e =>
     e Environment Action -> e Environment b

step stepEnv'
  :: MonadEnv s Outcome Environment e =>
     e Environment Action -> e Environment (Maybe Outcome)

lower . step stepEnv'
  :: MonadEnv s Outcome Environment e =>
     e Environment Action -> Environment (Maybe Outcome) 
-}

-- | Run an n-armed bandit environment
runEnvironment 
  :: (IORef BanditState) 
  -> EnvState -> Environment a -> IO (D.DList Outcome)
runEnvironment bs es (Environment m) = snd <$> evalRWST m bs es


act1 :: Environment ()
act1 = episode (O.Outcome 0 0) stepEnv (stepBandit 0.1)




episode :: Monad m => o -> (a -> m (Maybe o)) -> (o -> m a) -> m ()
episode o p f = go o
  where go o = do
          a <- f o
          mo <- p a
          case mo of
              Nothing -> return ()
              Just o' -> go o'

------------------------------------------------------------------------------

data EnvState = 
  EnvState { arms :: Vector N.NormalDistribution , gen :: R.GenIO, pulls :: Int }

instance Show EnvState where
  show c = "EnvState" ++
    "{ means = " ++ 
      show (fmap Dist.mean . V.toList $ arms c) ++ 
        ", pulls = " ++ show (pulls c) ++ " }"

stepEnv :: Action -> Environment (Maybe Outcome)
stepEnv action = do
  rwd <- genContVar =<< (! action) . arms <$> get
  modify $ \(EnvState a g p) -> EnvState a g (p+1)
  r <- ask
  liftIO $ modifyIORef r $ addStats action (Stats action rwd)
  n <- gets pulls
  return $ if n >= episodeLength then Nothing else Just $ O.Outcome action rwd

genContVar :: Dist.ContGen d => d -> Environment Double
genContVar d = do
  g <- gets gen
  liftIO $ Dist.genContVar d g

------------------------------------------------------------------------------
-- | Monad for an n-armed bandit environment

stepBandit :: Float -> Outcome -> Environment Action 
stepBandit eps o@(O.Outcome action rwd) = do
    tell . pure $ o
    r <- ask
    liftIO $ modifyIORef r $ addStats action (Stats action rwd)
    s <- liftIO $ readIORef r
    let rwds = Map.map mean s
    --liftIO $ print $ "rewards: " ++ show rwds
    -- modify $ \(EnvState a g p) -> EnvState a g (p+1)
    a <- epsilonGreedy (Map.toList rwds) eps
    return a

epsilonGreedy
  :: (R.Variate e, Ord e, Ord r) 
  => [(a, r)] -> e -> Environment a
epsilonGreedy acts = 
  epsilonChoice (fst $ maximumBy (comparing snd) acts) acts

epsilonChoice 
  :: (R.Variate e, Ord e) 
  => a -> [(a, r)] -> e -> Environment a
epsilonChoice a acts eps = do
  g <- gets gen
  compare eps <$> R.uniform g >>= \case
    LT -> pure a
    _  -> do
      i <- R.uniformR (0, length acts) g
      pure . fst . head $ drop (i-1) acts

------------------------------------------------------------------------------
-- | Statistics observed for a particular candidate.

data Stats = Stats
    { armCount :: !Int  -- ^ Number of times this candidate was observed
    , armTotal :: !Double -- ^ Total reward over all observations
    } deriving (Show, Eq)

instance Semigroup Stats where
    s <> s' = Stats { armCount = armCount s + armCount s'
                    , armTotal = armTotal s + armTotal s' }

instance Monoid Stats where
    mempty = Stats 0 0

-- | A record of statistics for all possibilities
type BanditState = Map.Map Action Stats

-- | Average reward over all observations for that arm.
mean :: Stats -> Reward
mean (Stats 0 _) = 0
mean ss = armTotal ss / toEnum (armCount ss)

addStats :: Action -> Stats -> BanditState -> BanditState
addStats = Map.insertWith (<>)

-}
