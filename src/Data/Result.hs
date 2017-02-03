{-# LANGUAGE DeriveFunctor #-}
module Data.Result where

import qualified Control.Monad.Fail as Fail
import Control.Applicative
import Data.Functor.Classes
import Text.Pretty

data Result a = Result a | Error [String]
  deriving (Eq, Functor, Show)


-- Instances

instance Applicative Result where
  pure = Result
  Error s <*> _ = Error s
  Result f <*> a = fmap f a

instance Monad Result where
  return = pure
  fail = Fail.fail
  Error s >>= _ = Error s
  Result a >>= f = f a

instance Fail.MonadFail Result where
  fail = Error . pure

instance Alternative Result where
  empty = Error []
  Error s1 <|> Error s2 = Error (s1 ++ s2)
  Result a <|> _ = Result a
  _ <|> Result b = Result b

instance Pretty1 Result where
  prettyPrec1 (Result a) = a
  prettyPrec1 (Error errors) = (0, foldr (.) id (fmap (\ e -> showString e . showChar '\n') errors))

instance Pretty a => Pretty (Result a) where
  prettyPrec = prettyPrec1 . fmap prettyPrec

instance Show1 Result where
  liftShowsPrec sp _ d result = case result of
    Error s -> showsUnaryWith showsPrec "Error" d s
    Result a -> showsUnaryWith sp "Result" d a
