{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE DeriveGeneric #-}


module LSC.Types where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Chan.Unagi
import Control.Lens hiding (element)
import Data.Aeson
import Data.Char
import Data.Default
import Data.Foldable
import Data.Function (on)
import Data.Map (Map, fromList, insert, unionWith, lookup, assocs)
import Data.Semigroup
import Data.Hashable
import Data.Text (Text)
import Data.Vector (Vector)

import Control.Monad.Codensity
import Control.Monad.Reader
import Control.Monad.State

import Data.Time.Clock.POSIX
import System.Console.Concurrent

import GHC.Generics
import Prelude hiding (lookup)

import LSC.Symbolic


data RTL = RTL
  { _identifier  :: Identifier
  , _description :: AbstractGate
  , _subcircuits :: Map Identifier RTL
  } deriving (Generic, Show)


data AbstractGate = AbstractGate [LogicPort] [Expr]
  deriving (Generic, Show)

instance Semigroup AbstractGate where
  AbstractGate ps es <> AbstractGate qs fs = AbstractGate (ps <> qs) (es <> fs)

instance Monoid AbstractGate where
  mempty = AbstractGate mempty mempty
  mappend = (<>)


data LogicPort = LogicPort
  { _identifier :: Identifier
  , _dir        :: Dir
  } deriving (Generic, Show)


data Expr
  = Assign Identifier Expr
  | Ref Identifier
  | And [Expr]
  deriving (Generic, Show)


data NetGraph = NetGraph
  { _identifier  :: Identifier
  , _supercell   :: AbstractCell
  , _subcells    :: Map Identifier NetGraph
  , _gates       :: Vector Gate
  , _nets        :: Map Identifier Net
  } deriving (Generic, Show)

instance ToJSON NetGraph
instance FromJSON NetGraph


type Contact = Pin

data Net = Net
  { _identifier :: Identifier
  , _geometry   :: Path
  , _contacts   :: Map Number [Contact]
  } deriving (Generic, Show)

instance ToJSON Net
instance FromJSON Net


type Number = Int

type Identifier = Text

data Gate = Gate
  { _identifier :: Identifier
  , _geometry   :: Path
  , _vdd        :: Pin
  , _gnd        :: Pin
  , _wires      :: Map Identifier Identifier
  , _number     :: Number
  } deriving (Generic, Show)

instance ToJSON Gate
instance FromJSON Gate


data AbstractCell = AbstractCell
  { _geometry  :: Path
  , _vdd       :: Pin
  , _gnd       :: Pin
  , _pins      :: Map Identifier Pin
  } deriving (Generic, Show)

instance ToJSON AbstractCell
instance FromJSON AbstractCell


data Cell = Cell
  { _pins       :: Map Identifier Pin
  , _vdd        :: Pin
  , _gnd        :: Pin
  , _dims       :: (Integer, Integer)
  } deriving (Generic, Show)

instance ToJSON Cell
instance FromJSON Cell


data Pin = Pin
  { _identifier :: Identifier
  , _dir        :: Dir
  , _ports      :: [Port]
  } deriving (Generic, Show)

instance ToJSON Pin
instance FromJSON Pin

instance Hashable Pin


type Port = Component Layer Integer


data Dir = In | Out | InOut
  deriving (Eq, Generic, Show)

instance ToJSON Dir
instance FromJSON Dir

instance Hashable Dir


data Layer
  = AnyLayer
  | Metal1
  | Metal2
  | Metal3
  deriving (Eq, Ord, Enum, Read, Generic, Show)

instance ToJSON Layer
instance FromJSON Layer

instance Hashable Layer


metal1, metal2, metal3 :: SLayer
metal1   = slayer Metal1
metal2   = slayer Metal2
metal3   = slayer Metal3

slayer :: Layer -> SLayer
slayer = literal . toEnum . fromEnum


data Technology = Technology
  { _scaleFactor    :: Double
  , _featureSize    :: Double
  , _stdCells       :: Map Text Cell
  , _standardPin    :: (Integer, Integer)
  , _rowSize        :: Integer
  } deriving (Generic, Show)

instance ToJSON Technology
instance FromJSON Technology


type BootstrapT m = StateT Technology m
type Bootstrap = State Technology

bootstrap :: (Technology -> Technology) -> Bootstrap ()
bootstrap = modify

freeze :: Bootstrap () -> Technology
freeze = flip execState def

thaw :: Technology -> Bootstrap ()
thaw = put

type GnosticT m = ReaderT Technology m
type Gnostic = GnosticT Agnostic

type Agnostic = Identity

technology :: LSC Technology
technology = lift $ LST $ lift ask

runGnosticT :: GnosticT m r -> Technology -> m r
runGnosticT = runReaderT

gnostic :: Bootstrap () -> Gnostic r -> r
gnostic b a = a `runReader` freeze b


data CompilerOpts = CompilerOpts
  { _jogs        :: Int
  , _rowSize     :: Integer
  , _halt        :: Int
  , _enableDebug :: Bool
  , _smtConfig   :: SMTConfig
  , _workers     :: Workers
  }

data Workers
  = Singleton
  | Workers (InChan (), OutChan ())

smtOption :: String -> SMTConfig
smtOption = d . fmap toLower
  where
    d "boolector" = boolector
    d "cvc4"      = cvc4
    d "yices"     = yices
    d "z3"        = z3
    d "mathsat"   = mathSAT
    d "abc"       = abc
    d _           = yices

type Environment = CompilerOpts

type EnvT m = ReaderT Environment m

environment :: LSC CompilerOpts
environment = lift $ LST ask

runEnvT :: Monad m => EnvT m r -> Environment -> m r
runEnvT = evalEnvT

evalEnvT :: Monad m => EnvT m r -> Environment -> m r
evalEnvT = runReaderT


type LSC = Codensity LST

liftSymbolic :: Symbolic a -> LSC a
liftSymbolic = lift . LST . lift . lift


newtype LST a = LST { unLST :: EnvT (GnosticT Symbolic) a }

instance Functor LST where
  fmap f (LST a) = LST (fmap f a)

instance Applicative LST where
  pure = LST . pure
  LST a <*> LST b = LST (a <*> b)

instance Monad LST where
  return = pure
  m >>= k = LST (unLST m >>= unLST . k)

instance MonadIO LST where
  liftIO = LST . liftIO


type Path = [Component Layer Integer]

type Ring l a = Component l (Component l a)

type SComponent = Component SLayer SInteger

type SLayer = SInteger

type SPath = [SComponent]

type SRing = Ring SInteger SInteger


data Component l a
  = Rect    { _l :: a, _b :: a, _r :: a, _t :: a }
  | Via     { _l :: a, _b :: a, _r :: a, _t :: a, _z :: [l] }
  | Layered { _l :: a, _b :: a, _r :: a, _t :: a, _z :: [l] }
  deriving (Eq, Functor, Foldable, Traversable, Generic, Show)

instance (ToJSON l, ToJSON a) => ToJSON (Component l a)
instance (FromJSON l, FromJSON a) => FromJSON (Component l a)

instance (Hashable l, Hashable a) => Hashable (Component l a)


makeFieldsNoPrefix ''Component

width, height :: Num a => Component l a -> a
width  p = p ^. r - p ^. l
height p = p ^. t - p ^. b

integrate :: l -> Component l a -> Component l a
integrate layer (Rect x1 y1 x2 y2) = Layered x1 y1 x2 y2 (pure layer)
integrate layer rect = over z (layer :) rect

setLayers :: Foldable f => f l -> Component k a -> Component l a
setLayers layer (Rect    x1 y1 x2 y2)   = Layered x1 y1 x2 y2 (toList layer)
setLayers layer (Via     x1 y1 x2 y2 _) = Via     x1 y1 x2 y2 (toList layer)
setLayers layer (Layered x1 y1 x2 y2 _) = Layered x1 y1 x2 y2 (toList layer)


instance Default a => Default (Component l a) where
  def = Rect def def def def


inner, outer :: Ring l a -> Component l a
inner p = Rect (p ^. l . r) (p ^. b . t) (p ^. r . l) (p ^. t . b)
outer p = Rect (p ^. l . l) (p ^. b . b) (p ^. r . r) (p ^. t . t)



makeFieldsNoPrefix ''RTL

instance Default RTL where
  def = RTL mempty mempty mempty


makeFieldsNoPrefix ''LogicPort



makeFieldsNoPrefix ''NetGraph

instance Default NetGraph where
  def = NetGraph mempty def mempty mempty mempty

instance Hashable NetGraph where
  hashWithSalt s a = hashWithSalt s
    ( a ^. identifier
    , a ^. supercell
    , a ^. subcells & assocs
    , a ^. gates & toList
    , a ^. nets & assocs
    )


treeStructure :: NetGraph -> NetGraph
treeStructure netlist = netlist & subcells .~ foldr collect mempty (netlist ^. gates)
  where
    scope = fromList [ (x ^. identifier, x) | x <- flatten subcells netlist ]
    collect g a = maybe a (descend a) $ lookup (g ^. identifier) scope
    descend a n = insert (n ^. identifier) (treeStructure n) a


flatten :: Foldable f => Getter a (f a) -> a -> [a]
flatten descend netlist
  = netlist
  : join [ flatten descend model | model <- toList $ netlist ^. descend ]


makeFieldsNoPrefix ''AbstractCell

instance Default AbstractCell where
  def = AbstractCell mempty def def mempty

instance Hashable AbstractCell where
  hashWithSalt s a = hashWithSalt s
    ( a ^. geometry
    , a ^. vdd
    , a ^. gnd
    , a ^. pins & assocs
    )


makeFieldsNoPrefix ''Net

instance Hashable Net where
  hashWithSalt s a = hashWithSalt s
    ( a ^. identifier
    , a ^. geometry
    , a ^. contacts & assocs
    )

instance Eq Net where
  (==) = (==) `on` view identifier

instance Ord Net where
  compare = compare `on` view identifier

instance Semigroup Net where
  Net i ns as <> Net _ os bs = Net i (ns <> os) (unionWith mappend as bs)

instance Monoid Net where
  mempty = Net mempty mempty mempty
  mappend = (<>)


makeFieldsNoPrefix ''Gate

instance Eq Gate where
  (==) = (==) `on` view number

instance Ord Gate where
  compare = compare `on` view number

instance Default Gate where
  def = Gate mempty mempty def def mempty def

instance Hashable Gate where
  hashWithSalt s a = hashWithSalt s
    ( a ^. identifier
    , a ^. geometry
    , (a ^. vdd, a ^. gnd)
    , a ^. wires & assocs
    , a ^. number
    )


type Arboresence a = (Net, a, a)

data Circuit2D a = Circuit2D [(Gate, a)] [Arboresence a]
  deriving (Eq, Show)


makeFieldsNoPrefix ''Cell

instance Default Cell where
  def = Cell mempty def def def

instance Hashable Cell where
  hashWithSalt s a = hashWithSalt s
    ( a ^. pins & assocs
    , a ^. vdd
    , a ^. gnd
    , a ^. dims
    )


makeFieldsNoPrefix ''Pin

instance Eq Pin where
  (==) = (==) `on` view identifier

instance Ord Pin where
  compare = compare `on` view identifier

instance Default Pin where
  def = Pin mempty In def


makeFieldsNoPrefix ''CompilerOpts

instance Default CompilerOpts where
  def = CompilerOpts 1 20000 (16 * 1000000) True yices Singleton


runLSC :: Environment -> Bootstrap () -> LSC a -> IO a
runLSC opts tech
  = runSMTWith (opts ^. smtConfig)
  . flip runGnosticT (freeze tech)
  . flip runEnvT opts
  . unLST
  . lowerCodensity

evalLSC :: Environment -> Bootstrap () -> LSC a -> IO a
evalLSC = runLSC


debug :: Foldable f => f String -> LSC ()
debug msg = do
  enabled <- view enableDebug <$> environment
  when enabled $ liftIO $ do
    time <- show . round <$> getPOSIXTime
    errorConcurrent $ unlines [unwords $ time : "->" : toList msg]


pushWorker :: LSC ()
pushWorker = do
  opts <- environment
  case opts ^. workers of
    Singleton -> pure ()
    Workers (in_, _) -> liftIO $ writeChan in_ ()

popWorker :: LSC ()
popWorker = do
  opts <- environment
  case opts ^. workers of
    Singleton -> pure ()
    Workers (_, out) -> liftIO $ readChan out


createWorkers :: Int -> IO Workers
createWorkers n | n < 2 = pure Singleton
createWorkers n = do
  (in_, out) <- newChan
  sequence_ $ replicate (n - 1) $ writeChan in_ ()
  pure $ Workers (in_, out)

rtsWorkers :: IO Workers
rtsWorkers = createWorkers =<< getNumCapabilities


makeFieldsNoPrefix ''Technology

instance Default Technology where
  def = Technology 1000 1 mempty (1000, 1000) 30000

instance Hashable Technology where
  hashWithSalt s a = hashWithSalt s
    ( a ^. scaleFactor
    , a ^. featureSize
    , a ^. stdCells & assocs
    , a ^. standardPin
    , a ^. rowSize
    )


lookupDimensions :: Gate -> Technology -> Maybe (Integer, Integer)
lookupDimensions g tech = view dims <$> lookup (g ^. identifier) (tech ^. stdCells)

lambda :: Technology -> Integer
lambda tech = ceiling $ view scaleFactor tech * view featureSize tech


divideArea :: Foldable f => f a -> LSC [Integer]
divideArea xs = do
  size <- view rowSize <$> environment
  tech <- technology
  let x = tech ^. standardPin . _1 & (* 2)
  pure $ take n $ x : iterate (join (+)) size
  where n = ceiling $ sqrt $ fromIntegral $ length xs
