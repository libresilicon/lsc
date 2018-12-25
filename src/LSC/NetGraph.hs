
module LSC.NetGraph where

import Control.Monad
import Data.Foldable
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Map.Internal.Debug
import Data.Text (unpack)
import qualified Data.Vector as Vector

import LSC.Types


type Leaves = Map String Integer


getLeaves :: NetGraph -> [NetGraph]
getLeaves netlist | null $ subModels netlist = [netlist]
getLeaves netlist = getLeaves =<< toList (subModels netlist)


flattenHierarchy :: NetGraph -> [NetGraph]
flattenHierarchy netlist
  = netlist
  : join [ flattenHierarchy model | model <- toList $ subModels netlist ]


showGraph :: NetGraph -> String
showGraph netlist = showTreeWith
  ( \ k x -> unwords [unpack k, showGraph x] )
  True
  True
  (subModels netlist)


showNetHierarchy :: NetGraph -> String
showNetHierarchy netlist = unlines [ showNetHierarchy m | m <- toList $ subModels netlist ]
  ++ unlines
  [ mempty
  , "model: " ++ unpack (modelName netlist)
  , mempty
  , "Total: " ++ show (Vector.length $ gateVector netlist)
  ]
  ++ unlines [ unpack g ++ ": " ++ show c | (g, c) <- Map.assocs gates ]
  where
    gates = Map.fromListWith (+) [ (gateIdent g, 1 :: Int) | g <- toList $ gateVector netlist ]

