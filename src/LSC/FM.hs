{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module LSC.FM where

import Control.Conditional (whenM)
import Control.Lens hiding (indexed, imap)
import Control.Monad
import Control.Monad.Loops
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.ST
import Data.Foldable
import Data.Function
import Data.Maybe
import Data.Monoid
import Data.HashTable.ST.Cuckoo (HashTable)
import Data.HashTable.ST.Cuckoo (mutate, lookup, new, newSized)
import Data.IntSet hiding (filter, null, foldr, foldl', toList)
import qualified Data.IntSet as S
import Data.Ratio
import Data.STRef
import Data.Vector
  ( Vector
  , unsafeFreeze, unsafeThaw
  , freeze, thaw
  , take, generate
  , (!), indexed, unzip
  , imap, unstablePartition
  )
import Data.Vector.Mutable (MVector, read, write, modify, replicate, unsafeSwap, slice)
import qualified Data.Vector.Algorithms.Intro as Intro
import Prelude hiding (replicate, length, read, lookup, take, drop, head, unzip)
import System.Random.MWC

import LSC.Entropy
import LSC.Types (V, E)



matchingRatio :: Rational
matchingRatio = 1 % 3

coarseningThreshold :: Int
coarseningThreshold = 8


balanceFactor :: Rational
balanceFactor = 1 % 10



data Gain s a = Gain
  (STRef s IntSet)      -- track existing gains
  (MVector s Int)       -- gains indexed by node
  (HashTable s Int [a]) -- nodes indexed by gain



data Move
  = Move Int Int -- Move Gain Cell
  deriving Show


data Lock = Lock
  { _lft :: !IntSet
  , _rgt :: !IntSet
  } deriving Show

makeLenses ''Lock


instance Semigroup Lock where
  a <> b = a &~ do
    lft <>= view lft b
    rgt <>= view rgt b

instance Monoid Lock where
  mempty = Lock mempty mempty
  mappend = (<>)


lockSwap :: Lock -> Lock
lockSwap lock = lock &~ do
    lft .= view rgt lock
    rgt .= view lft lock



data Bipartitioning = Bisect !IntSet !IntSet


instance Eq Bipartitioning where
  Bisect a _ == Bisect b _ = a == b


instance Semigroup Bipartitioning where
  Bisect a b <> Bisect c d = Bisect (a <> c) (b <> d)

instance Monoid Bipartitioning where
  mempty = Bisect mempty mempty
  mappend = (<>)


instance Show Bipartitioning where
  show (Bisect a b) = "<"++ show a ++", "++ show b ++">"


move :: Int -> Bipartitioning -> Bipartitioning
move c (Bisect a b) | member c a = Bisect (delete c a) (insert c b)
move c (Bisect a b) = Bisect (insert c a) (delete c b)


bisectBalance :: Bipartitioning -> Int
bisectBalance (Bisect a b) = abs $ size a - size b

bisectSwap :: Bipartitioning -> Bipartitioning
bisectSwap (Bisect p q) = Bisect q p


cutSize :: (V, E) -> Bipartitioning -> Int
cutSize (v, _) (Bisect p q) = size $ intersection
    (foldMap (v!) $ elems p)
    (foldMap (v!) $ elems q)



type Clustering = Vector IntSet


type Permutation = Vector Int



data Heu s = Heu
  { _gains        :: Gain s Int
  , _freeCells    :: IntSet
  , _moves        :: [(Move, Bipartitioning)]
  }

makeFieldsNoPrefix ''Heu


type FM s = ReaderT (Gen s, STRef s (Heu s)) (ST s)



nonDeterministic :: FM RealWorld a -> IO a
nonDeterministic f = do
  v <- entropyVector32 258
  stToIO $ do
      g <- initialize v
      runFMWithGen g f


prng :: FM s (Gen s)
prng = fst <$> ask


evalFM :: FM s a -> ST s a
evalFM = runFM

runFM :: FM s a -> ST s a
runFM f = do
    gen <- create
    runFMWithGen gen f

runFMWithGen :: Gen s -> FM s a -> ST s a
runFMWithGen s f = do
  g <- Gain <$> newSTRef mempty <*> thaw mempty <*> new
  r <- newSTRef $ Heu g mempty mempty
  runReaderT f (s, r)


st :: ST s a -> FM s a
st = lift


update :: Simple Setter (Heu s) a -> (a -> a) -> FM s ()
update v f = do
  r <- modifySTRef . snd <$> ask
  st $ r $ v %~ f

value :: Getter (Heu s) a -> FM s a
value v = view v <$> snapshot

snapshot :: FM s (Heu s)
snapshot = st . readSTRef . snd =<< ask


-- | This function does not reach all possible permutations for lists
--   consisting of more than 969 elements. Any PRNGs possible states
--   are bound by its possible seed values.
--   In the case of MWC8222 the period is 2^8222 which allows for
--   not more than 969! different states.
--
-- seed bits: 8222
-- maximum list length: 969
--
--   969! =~ 2^8222
--
-- Monotonicity of  n! / (2^n): 
--
-- desired seed bits: 256909
-- desired list length: 20000
--
--   20000! =~ 2^256909
--
randomPermutation :: Int -> FM s Permutation
randomPermutation n = do
  v <- unsafeThaw $ generate n id
  for_ [0 .. n - 2] $ \ i -> unsafeSwap v i =<< uniformR (i, n - 1) =<< prng
  unsafeFreeze v



fmMultiLevel :: (V, E) -> Lock -> Int -> Rational -> FM s Bipartitioning
fmMultiLevel (v, e) lock t r = do

    i <- st $ newSTRef 0

    let it = 64

    hypergraphs  <- replicate it mempty
    locks        <- replicate it mempty
    clusterings  <- replicate it mempty
    partitioning <- replicate it mempty

    write hypergraphs 0 (v, e)
    write locks 0 lock

    let continue = st $ do
            j <- readSTRef i
            l <- length . fst <$> read hypergraphs j
            s <- freeze $ slice (max 0 $ j-8) (min 8 $ it-j) hypergraphs
            pure $ j < pred it && t <= l && any (l /=) (length . fst <$> s)
    whileM_ continue $ do

      hi <- st $ read hypergraphs =<< readSTRef i
      u <- randomPermutation $ length $ fst hi

      st $ do

        modifySTRef' i succ

        -- interim clustering
        (pk, lk) <- match hi lock r u

        -- interim hypergraph
        hs <- induce hi pk

        j <- readSTRef i
        write clusterings j pk
        write hypergraphs j hs
        write locks j lk


    -- number of levels
    m <- st $ readSTRef i

    by <- read hypergraphs m
    lk <- read locks m
    write partitioning m =<< bipartition by lk =<< bipartitionRandom by lk

    for_ (reverse [0 .. pred m]) $ \ j -> do
        pk <- read clusterings  $ succ j
        p  <- read partitioning $ succ j

        l <- read locks j
        h <- read hypergraphs j
        q <- rebalance =<< project pk p

        write partitioning j =<< bipartition h l q

    read partitioning 0




refit :: (V, E) -> Int -> Lock -> Bipartitioning -> Bipartitioning
refit _ k _ (Bisect p q)
    | size p <= k
    , size q <= k
    = Bisect p q
refit (v, e) k lock (Bisect p q)
    | size p + size q > 2 * k
    = error
    $ "impossible size: "++ show (lock, size p, size q, k, p, q, length v, length e)
refit _ _ _ (Bisect p q)
    | size p == size q
    = Bisect p q
refit (v, e) k lock (Bisect p q)
    | size p < size q
    = bisectSwap $ refit (v, e) k (lockSwap lock) (bisectSwap $ Bisect p q) 
refit (v, e) k lock (Bisect p q) = runST $ do

    let f x = size . intersection x . foldMap (e!) . elems
        len = size p - k

    u <- thaw
        $ uncurry (<>)
        $ unstablePartition (\ (i, _) -> notMember i $ lock ^. lft)
        $ fst 
        $ unstablePartition (\ (i, _) -> member i p)
        $ imap (,) v
    Intro.partialSortBy (compare `on` \ (_, x) -> f p x - f q x) u len
    (iv, _) <- unzip . take len <$> unsafeFreeze u

    when (length iv < len) $ error $ show $ (iv, len)

    pure $ Bisect (ala Endo foldMap (delete <$> iv) p) (ala Endo foldMap (insert <$> iv) q)



rebalance :: Bipartitioning -> FM s Bipartitioning
rebalance (Bisect p q)
  | size p < size q
  = bisectSwap <$> rebalance (bisectSwap $ Bisect p q)
rebalance (Bisect p q) = do
  free <- value freeCells
  if balanceCriterion free (Bisect p q) minBound
  then do
    u <- randomPermutation $ size p + size q
    st $ do
      b <- newSTRef $ Bisect p q
      i <- newSTRef 0
      let imba x j = j < size p + size q && (not $ balanceCriterion free x (u!j))
      whileM_ (imba <$> readSTRef b <*> readSTRef i)
        $ do
          j <- (u!) <$> readSTRef i
          when (member j p) $ modifySTRef b $ move j
          modifySTRef' i succ
      readSTRef b
  else pure $ Bisect p q



induce :: (V, E) -> Clustering -> ST s (V, E)
induce (v, e) pk = inputRoutine (length e) (length pk)
    [ (j, k)
    | (k, cluster) <- toList $ indexed pk
    , i <- elems cluster, j <- elems $ v!i
    ]


project :: Clustering -> Bipartitioning -> FM s Bipartitioning
project pk (Bisect p q) = pure $ Bisect 
    (foldMap (pk!) $ elems p)
    (foldMap (pk!) $ elems q)



match :: (V, E) -> Lock -> Rational -> Permutation -> ST s (Clustering, Lock)
match (v, e) lock r u = do

  clusteredLock <- newSTRef mempty
  clustering <- replicate (length v) mempty

  nMatch <- newSTRef 0
  k <- newSTRef 0
  j <- newSTRef 0

  connectivity <- replicate (length v) 0

  sights <- replicate (length v) False
  let yet n = not <$> read sights n
      matched n = write sights n True

  let continue n i = i < length v && n % fromIntegral (length v) < r
  whileM_ (continue <$> readSTRef nMatch <*> readSTRef j)
    $ do

      uj <- (u!) <$> readSTRef j
      whenM (yet uj) $ do

          modify clustering (insert uj) =<< readSTRef k
          matched uj

          let neighbours = elems $ foldMap (e!) (elems $ v!uj)

          for_ neighbours $ \ w ->
            whenM (yet w)
              $ unless (member w (view (lft <> rgt) lock) && member uj (view (lft <> rgt) lock))
                $ write connectivity w $ conn w uj

          -- find maximum connectivity
          suchaw <- newSTRef (0, Nothing)
          for_ neighbours $ \ w -> do
              cmax <- fst <$> readSTRef suchaw
              next <- read connectivity w
              when (next > cmax) $ writeSTRef suchaw (next, pure w)

          exists <- snd <$> readSTRef suchaw

          for_ exists $ \ w -> do
              modify clustering (insert w) =<< readSTRef k
              matched w
              modifySTRef' nMatch (+2)

              when (member w (view lft lock) || member uj (view lft lock))
                  $ modifySTRef clusteredLock . over lft . insert =<< readSTRef k
              when (member w (view rgt lock) || member uj (view rgt lock))
                  $ modifySTRef clusteredLock . over rgt . insert =<< readSTRef k


          -- reset connectivity
          for_ neighbours $ modify connectivity (const 0)

          modifySTRef' k succ

      modifySTRef' j succ

  whileM_ ((< length v) <$> readSTRef j)
    $ do

      uj <- (u!) <$> readSTRef j
      whenM (yet uj) $ do
          modify clustering (insert uj) =<< readSTRef k
          matched uj
          modifySTRef' k succ

          when (member uj (view lft lock))
              $ modifySTRef clusteredLock . over lft . insert =<< readSTRef k
          when (member uj (view rgt lock))
              $ modifySTRef clusteredLock . over rgt . insert =<< readSTRef k

      modifySTRef' j succ

  (,)
    <$> (take <$> readSTRef k <*> unsafeFreeze clustering)
    <*> readSTRef clusteredLock

  where

      -- cost centre!
      conn i j = sum [ 1 % size (e!x) | x <- elems $ intersection (v'!i) (v'!j) ]
      v' = S.filter (\x -> size (e!x) <= 10) <$> v




bipartitionEven :: (V, E) -> Lock -> Bipartitioning
bipartitionEven (v, _) lock = Bisect
    ((S.filter even base <> intersection base (view lft lock)) \\ view rgt lock)
    ((S.filter  odd base <> intersection base (view rgt lock)) \\ view lft lock)
    where base = fromDistinctAscList [0 .. length v - 1]



bipartitionRandom :: (V, E) -> Lock -> FM s Bipartitioning
bipartitionRandom (v, _) lock = do
  u <- randomPermutation $ length v
  let (p, q) = splitAt (length v `div` 2) (toList u)
  pure $ Bisect
    ((fromList p <> intersection base (view lft lock)) \\ view rgt lock)
    ((fromList q <> intersection base (view rgt lock)) \\ view lft lock)
  where base = fromDistinctAscList [0 .. length v - 1]



bipartition :: (V, E) -> Lock -> Bipartitioning -> FM s Bipartitioning
bipartition (v, e) lock p = do

  update freeCells $ const $ fromAscList [0 .. length v - 1] \\ view (lft <> rgt) lock
  update moves $ const mempty

  initialGains (v, e) p
  processCell (v, e) p

  (g, q) <- computeG p . reverse <$> value moves

  if g <= 0
    then pure p
    else bipartition (v, e) lock q



computeG :: Foldable f => Bipartitioning -> f (Move, Bipartitioning) -> (Int, Bipartitioning)
computeG p0 ms = let (_, g, h) = foldl' accum (0, 0, p0) ms in (g, h)
  where
    accum :: (Int, Int, Bipartitioning) -> (Move, Bipartitioning) -> (Int, Int, Bipartitioning)
    accum (gmax, g, _) (Move gc _, q)
        | g + gc > gmax
        = (g + gc, g + gc, q)
    accum (gmax, g, p) (Move gc _, q)
        | g + gc == gmax
        , bisectBalance p > bisectBalance q
        = (gmax, g + gc, q)
    accum (gmax, g, p) (Move gc _, _)
        = (gmax, g + gc, p)



processCell :: (V, E) -> Bipartitioning -> FM s ()
processCell (v, e) p = do
  ck <- selectBaseCell p
  for_ ck $ \ c -> do
    lockCell c
    q <- moveCell c p
    updateGains c (v, e) p
    processCell (v, e) q


lockCell :: Int -> FM s ()
lockCell c = do
  update freeCells $ delete c
  removeGain c


moveCell :: Int -> Bipartitioning -> FM s Bipartitioning
moveCell c p = do
  Gain _ u _ <- value gains
  g <- st $ read u c
  let q = move c p
  update moves $ cons (Move g c, q)
  pure q



selectBaseCell :: Bipartitioning -> FM s (Maybe Int)
selectBaseCell p = do
  bucket <- maxGain
  free <- value freeCells
  case bucket of
    Just (g, []) -> error $ show g
    Just (_, xs) -> pure $ balanceCriterion free p `find` xs
    _ -> pure Nothing



updateGains :: Int -> (V, E) -> Bipartitioning -> FM s ()
updateGains c (v, e) p = do

  let f = fromBlock p c e
      t = toBlock p c e

  free <- value freeCells

  for_ (elems $ v ! c) $ \ n -> do

    -- reflect changes before the move
    when (size (t n) == 0) $ for_ (elems $ f n `intersection` free) (modifyGain succ)
    when (size (t n) == 1) $ for_ (elems $ t n `intersection` free) (modifyGain pred)

    -- reflect changes after the move
    when (size (f n) == succ 0) $ for_ (elems $ t n `intersection` free) (modifyGain pred)
    when (size (f n) == succ 1) $ for_ (elems $ f n `intersection` free) (modifyGain succ)



maxGain :: FM s (Maybe (Int, [Int]))
maxGain = do
  Gain gmax _ m <- value gains
  mg <- st $ maxView <$> readSTRef gmax
  case mg of
    Just (g, _) -> do
      mb <- st $ lookup m g
      pure $ (g, ) <$> mb
    _ -> pure Nothing


removeGain :: Int -> FM s ()
removeGain c = do

  Gain gmax u m <- value gains

  st $ do

    j <- read u c

    mg <- lookup m j
    for_ mg $ \ ds -> do

        when (ds == pure c) $ modifySTRef gmax $ delete j
        mutate m j $ (, ()) . fmap (filter (/= c))



modifyGain :: (Int -> Int) -> Int -> FM s ()
modifyGain f c = do

  Gain gmax u m <- value gains

  st $ do

    j <- read u c
    modify u f c

    mg <- lookup m j
    for_ mg $ \ ds -> do

        when (ds == pure c) $ modifySTRef gmax $ delete j
        mutate m j $ (, ()) . fmap (filter (/= c))

        modifySTRef gmax $ insert (f j)
        mutate m (f j) $ (, ()) . pure . maybe [c] (c:)



initialGains :: (V, E) -> Bipartitioning -> FM s ()
initialGains (v, e) p = do

  free <- value freeCells

  let nodes = flip imap v $ \ i ns ->
        let f = fromBlock p i e
            t = toBlock p i e
         in size (S.filter (\ n -> size (f n) == 1) ns)
          - size (S.filter (\ n -> size (t n) == 0) ns)

  let gmax = foldMap singleton nodes

  initial <- st $ do
      gain <- newSized $ 2 * size gmax + 1
      flip imapM_ nodes $ \ k x ->
          mutate gain x $ if member x free
             then (, ()) . pure . maybe [k] (k:)
             else (, ())
      Gain <$> newSTRef gmax <*> thaw nodes <*> pure gain

  update gains $ const initial



balanceCriterion :: IntSet -> Bipartitioning -> Int -> Bool
balanceCriterion free (Bisect p q) c
    | size p > size q
    = balanceCriterion free (Bisect q p) c
balanceCriterion free (Bisect p q) c
    =  (fromIntegral (size free) * (1 - r)) / 2 <= fromIntegral a
    && (fromIntegral (size free) * (1 + r)) / 2 >= fromIntegral b
  where
    a = last (succ : [pred | member c p]) (size $ intersection free p)
    b = last (succ : [pred | member c q]) (size $ intersection free q)
    r = balanceFactor


fromBlock, toBlock :: Bipartitioning -> Int -> E -> Int -> IntSet
fromBlock (Bisect a _) i e n | member i a = intersection a $ e ! n
fromBlock (Bisect _ b) _ e n = intersection b $ e ! n
toBlock (Bisect a b) i e n | member i a = intersection b $ e ! n
toBlock (Bisect a _) _ e n = intersection a $ e ! n


inputRoutine :: Foldable f => Int -> Int -> f (Int, Int) -> ST s (V, E)
inputRoutine n c xs = do
  ns <- replicate n mempty
  cs <- replicate c mempty
  for_ xs $ \ (x, y) -> do
    modify ns (insert y) x
    modify cs (insert x) y
  (,) <$> freeze cs <*> freeze ns

