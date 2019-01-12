
module Liberty.Tokens
    ( Lexer (..)
    , Pos
    , Token (..)
    ) where


data Lexer a = L Pos a
  deriving (Show, Eq)

type Pos = (Int, Int)

data Token
    -- Keywords
    = Tok_Abstract
    | Tok_As
  deriving (Eq, Show)
