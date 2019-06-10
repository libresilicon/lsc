{-# LANGUAGE TemplateHaskell #-}

module LSC.FastDP where

import Control.Lens hiding (indices)
import Control.Monad.ST
import Control.Monad.Reader
import Data.Foldable
import Data.IntSet (size, elems, delete)
import Data.Matrix hiding ((!), fromList, toList)
import Data.Vector (Vector, fromListN, (!), unzip, freeze)
import Data.Vector.Mutable hiding (length)
import System.Random.MWC

import Prelude hiding (read, unzip, length)

import LSC.Entropy
import LSC.Median
import LSC.Types (V, E, Component(..), l, b, r, t)



type Cartesian = (Int, Int)
type Rectangle = Component () Int


type Position s = MVector s Cartesian
type Bounding s = MVector s Rectangle

type RowMatrix s = MVector s Int


data MatrixState s = MatrixState
    { _positions :: MVector s Cartesian
    , _indices   :: MVector s Int
    , _rowSize   :: Int
    }

makeLenses ''MatrixState


type DP s = ReaderT (Gen s, MatrixState s) (ST s)


fastDP_rnd :: (V, E) -> Matrix Int -> IO (Matrix Int)
fastDP_rnd (v, e) m = do
  u <- entropyVector32 258
  stToIO $ do
    s <- (,) <$> initialize u <*> thawPositions m
    flip runReaderT s $ do
      for_ [1 .. 10000] $ \ _ -> do
        globalSwap   (v, e) =<< uniformR (0, length v - 1) =<< prng
        verticalSwap (v, e) =<< uniformR (0, length v - 1) =<< prng
      positionMatrix m


fastDP :: (V, E) -> Matrix Int -> ST s (Matrix Int)
fastDP (v, e) m = do
  s <- (,) <$> create <*> thawPositions m
  flip runReaderT s $ do
    for_ [1 .. 10000] $ \ _ -> do
      globalSwap   (v, e) =<< uniformR (0, length v - 1) =<< prng
      verticalSwap (v, e) =<< uniformR (0, length v - 1) =<< prng
    positionMatrix m


prng :: DP s (Gen s)
prng = fst <$> ask



thawPositions :: Matrix Int -> ST s (MatrixState s)
thawPositions m = do
  p <- new $ succ $ maximum m
  q <- new $ nrows m * ncols m
  sequence_
    [ do
      when (x >= 0) $ write p x (pred i, pred j)
      write q (pred i * nrows m + pred j) x
    | i <- [1 .. nrows m]
    , j <- [1 .. ncols m]
    , let x = getElem i j m
    ]
  pure $ MatrixState p q (nrows m)



readPos :: Int -> DP s Cartesian
readPos c = do
    p <- view positions . snd <$> ask
    read p c



writePos :: Int -> Cartesian -> DP s ()
writePos c (i, j) = do
    MatrixState p q k <- snd <$> ask
    write p c (i, j)
    write q (i * k + j) c



swapPos :: Int -> Int -> DP s ()
swapPos i j = do
    MatrixState p q k <- snd <$> ask
    swap p i j
    (vi, vj) <- read p i
    (wi, wj) <- read p j
    swap q (vi * k + vj) (wi * k + wj)



moveTo :: Int -> (Int, Int) -> DP s ()
moveTo i (x, y) = do
    MatrixState p q k <- snd <$> ask
    j <- read q (x * k + y)
    if j < 0
      then do
        (x1, y1) <- read p i
        write q (x1 * k + y1) (-1)
        write q (x * k + y) i
        write p i (x, y)
      else swapPos i j



boundingBoxes :: (V, E) -> Int -> DP s (Vector Rectangle)
boundingBoxes (v, e) c = do
  fromListN (size $ v!c) <$> sequence
    [ do
      s <- sequence $ readPos <$> fromListN (size cs) (elems cs)
      let (xs, ys) = unzip s
      pure $ Rect (minimum xs) (minimum ys) (maximum xs) (maximum ys)
    | cs <- delete c . (e!) <$> elems (v!c)
    , size cs > 0
    ]



median :: Vector Rectangle -> Cartesian
median rs =
    ( exactMedian $ fmap (^.l) rs <> fmap (^.r) rs
    , exactMedian $ fmap (^.b) rs <> fmap (^.t) rs
    )



positionMatrix :: Matrix Int -> DP s (Matrix Int)
positionMatrix m = do
    q <- view indices . snd <$> ask
    k <- view rowSize . snd <$> ask
    v <- freeze q
    pure $ matrix (nrows m) (ncols m) $ \ (i, j) -> v ! (pred i * k + pred j)



globalSwap :: (V, E) -> Int -> DP s ()
globalSwap (v, e) c = do
    (i, j) <- median <$> boundingBoxes (v, e) c
    moveTo c (i, j)



verticalSwap :: (V, E) -> Int -> DP s ()
verticalSwap (v, e) c = do
    (i, j) <- median <$> boundingBoxes (v, e) c
    (x, y) <- readPos c
    if x == i
      then moveTo c (i, j)
      else if x < i
        then moveTo c (succ x, y + div (j - y) (i - x))
        else moveTo c (pred x, y + div (j - y) (x - i))



localReordering :: (V, E) -> Int -> Matrix Int -> Matrix Int
localReordering = undefined

