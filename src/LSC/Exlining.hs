{-# LANGUAGE TypeFamilies, ParallelListComp #-}

module LSC.Exlining where

import Data.Monoid
import Control.Monad
import Data.Foldable
import Data.Function
import Data.Hashable
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector hiding (replicate, foldl', null, toList, length, zip, foldr, elem)
import TextShow

import LSC.Types
import LSC.SuffixTree


exline k (Netlist name pins subs nodes edges)
  | not $ null maxr
  = Netlist name pins

  (Map.insert (modelName abstractNetlist) abstractNetlist subs)

  mempty -- nodes

  mempty -- edges

  where

    ((len, pos, _) : _) = maxr
    maxr = maximalRepeatsDisjoint (hash . gateIdent) nodes k

    scope = slice p1 len nodes
    p1 : _ = pos

    abstractNetlist
      = Netlist
      (buildName scope)
      (inputIdents closure scope, error $ show closure, mempty)
      mempty mempty mempty
    abstractGate = Gate mempty mempty 0

    closure = Map.fromListWith Set.union
      [ (i, Set.singleton x)
      | p <- pos
      , let inner = slice p len nodes
      , let outer = slice 0 p nodes <> slice (p + len) (length nodes - p - len) nodes
      , (i, x) <- Map.elems $ scopeWires inner `Map.intersection` scopeWires outer
      ]

exline _ netlist = netlist


scopeWires :: Foldable f => f Gate -> Map Identifier (Int, Wire)
scopeWires nodes = Map.fromList
  [ (k, (i, x))
  | (i, node) <- [0..] `zip` toList nodes
  , (x, k) <- gateWires node
  ]


buildName :: (Functor f, Foldable f) => f Gate -> Identifier
buildName = showt . abs . hash . foldr mappend mempty . fmap gateIdent


inputIdents :: Foldable f => Map Int (Set Identifier) -> f Gate -> [Identifier]
inputIdents closure scope =
  [ x <> showt i
  | (i, node) <- [0..] `zip` toList scope
  , (x, _) <- gateWires node
  , maybe False (x `elem`) (Map.lookup i closure)
  ]

outputIdents = undefined

