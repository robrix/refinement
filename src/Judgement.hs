{-# LANGUAGE FlexibleInstances, GADTs, RankNTypes #-}
module Judgement where

import Context hiding (S)
import qualified Context
import Control.Monad hiding (fail)
import Control.Monad.Free.Freer
import Data.Functor.Classes
import Data.Functor.Foldable
import Data.Result
import Expr
import Prelude hiding (fail)
import Text.Pretty

data Judgement a where
  Check :: Term -> Type -> Judgement ()
  Infer :: Term -> Judgement Type

  IsType :: Term -> Judgement ()

data State s a where
  Get :: State s s
  Put :: s -> State s ()


class Binder a where
  isBound :: Name -> a -> Bool

class Binder1 f where
  liftIsBound :: (Name -> a -> Bool) -> Name -> f a -> Bool

instance (Foldable t, Binder a) => Binder (t a) where
  isBound name = any (isBound name)

instance Binder Name where isBound = (==)

instance Binder TypeEntry where
  isBound name (_ := Known t) = isBound name t
  isBound _ _ = False

instance Binder1 f => Binder (Fix f) where
   isBound name = liftIsBound isBound name . unfix

instance Binder1 ExprF where
  liftIsBound isBound name = any (isBound name)


unify :: Type -> Type -> Proof ()
unify t1 t2 = case (unfix t1, unfix t2) of
  (Function a1 b1, Function a2 b2) -> unify a1 a2 >> unify b1 b2
  (Product a1 b1, Product a2 b2) -> unify a1 a2 >> unify b1 b2
  (Sum a1 b1, Sum a2 b2) -> unify a1 a2 >> unify b1 b2
  (UnitT, UnitT) -> return ()
  (TypeT, TypeT) -> return ()

  (Abs _ b1, Abs _ b2) -> unify b1 b2 -- this should probably be pushing unknown declarations onto the context
  (Var v1, Var v2) -> onTop $ \ (n := d) ->
    case (n == v1, n == v2, d) of
      (True, True, _) -> restore
      (True, False, Unknown) -> replace [ v1 := Known (var v2) ]
      (False, True, Unknown) -> replace [ v2 := Known (var v1) ]
      (True, False, Known t) -> unify t2 t >> restore
      (False, True, Known t) -> unify t1 t >> restore
      (False, False, _) -> unify t1 t2 >> restore
  (Var v, _) -> solve v [] t1
  (_, Var v) -> solve v [] t2
  (App a1 b1, App a2 b2) -> unify a1 a2 >> unify b1 b2

  (InL l1, InL l2) -> unify l1 l2
  (InR r1, InR r2) -> unify r1 r2
  (Case c1 l1 r1, Case c2 l2 r2) -> unify c1 c2 >> unify l1 l2 >> unify r1 r2

  (Pair a1 b1, Pair a2 b2) -> unify a1 a2 >> unify b1 b2
  (Fst p1, Fst p2) -> unify p1 p2
  (Snd p1, Snd p2) -> unify p1 p2

  (Unit, Unit) -> return ()

  _ -> fail ("Cannot unify " ++ pretty t1 ++ " with " ++ pretty t2)


solve :: Name -> Suffix -> Type -> Proof ()
solve name suffix ty = onTop $ \ (n := d) ->
  case (n == name, isBound n ty || isBound n suffix, d) of
    (True, True, _) -> fail "Occurs check failed."
    (True, False, Unknown) -> replace (suffix ++ [ name := Known ty ])
    (True, False, Known v) -> do
      modifyContext (<>< suffix)
      unify v ty
      restore
    (False, True, _) -> do
      solve name (n := d : suffix) ty
      replace suffix
    (False, False, _) -> do
      solve name suffix ty
      restore

specialize :: Scheme -> Proof Type
specialize (Type t) = return t
specialize s = do
  let (d, s') = unpack s
  b <- fresh d
  specialize (fmap (fromS b) s')
  where unpack :: Scheme -> (Declaration, Schm (Index Name))
        unpack (Context.All s') = (Unknown, s')
        unpack (LetS t s') = (Known t, s')
        unpack (Type _) = error "unpack cannot be called with a Type Schm."

        fromS :: Name -> Index Name -> Name
        fromS b Z = b
        fromS _ (Context.S a) = a


data ProofF a = J (Judgement a) | S (State (Name, Context) a) | R (Result a)

type Proof = Freer ProofF

getContext :: Proof Context
getContext = gets snd

putContext :: Context -> Proof ()
putContext context = do
  m <- gets fst
  put (m, context)

modifyContext :: (Context -> Context) -> Proof ()
modifyContext f = getContext >>= putContext . f

get :: Proof (Name, Context)
get = S Get `andThen` return

gets :: ((Name, Context) -> result) -> Proof result
gets f = fmap f get

put :: (Name, Context) -> Proof ()
put s = S (Put s) `andThen` return


andThen :: f x -> (x -> Freer f a) -> Freer f a
andThen = (Freer .) . flip Free

fresh :: Declaration -> Proof Name
fresh d = do
  (m, context) <- get
  put (increment m, context :< Ty (m := d))
  return m
  where increment (Name n) = Name (succ n)

onTop :: (TypeEntry -> Proof Extension) -> Proof ()
onTop f = do
  context :< vd <- getContext
  putContext context
  case vd of
    Ty d -> do
      m <- f d
      case m of
        Replace with -> modifyContext (<>< with)
        Restore -> modifyContext (:< vd)

    _ -> onTop f >> modifyContext (:< vd)

restore :: Proof Extension
restore = return Restore

replace :: Suffix -> Proof Extension
replace = return . Replace


infer :: Term -> Proof Type
infer term = J (Infer term) `andThen` return

check :: Term -> Type -> Proof ()
check term ty = J (Check term ty) `andThen` return

isType :: Term -> Proof ()
isType term = J (IsType term) `andThen` return


define :: Name -> Type -> Proof ()
define name ty = modifyContext (<>< [ name := Known ty ])

find :: Name -> Proof Scheme
find name = getContext >>= help
  where help (context :< Tm (found `Is` decl))
          | name == found = return decl
          | otherwise = help context
        help _ = fail ("Missing variable " ++ pretty name ++ " in context.")


fail :: String -> Proof a
fail = wrap . R . Error . (:[])


decompose :: Judgement a -> Proof a
decompose judgement = case judgement of
  Infer term -> case unfix term of
    Pair x y -> do
      a <- infer x
      b <- infer y
      return (a .*. b)

    Fst p -> do
      ty <- infer p
      case unfix ty of
        Product a _ -> return a
        _ -> fail ("Expected a product type, but got " ++ pretty ty)

    Snd p -> do
      ty <- infer p
      case unfix ty of
        Product _ b -> return b
        _ -> fail ("Expected a product type, but got " ++ pretty ty)

    InL l -> do
      a <- infer l
      b <- fresh Unknown
      return (a .+. var b)

    InR r -> do
      a <- fresh Unknown
      b <- infer r
      return (var a .+. b)

    Case subject ifL ifR -> do
      ty <- infer subject
      case unfix ty of
        Sum l r -> do
          b <- fresh Unknown
          check (l .->. var b) ifL
          check (r .->. var b) ifR
          return (var b)
        _ -> fail ("Expected a sum type, but got " ++ pretty ty)

    Unit -> return unitT

    Var name -> find name >>= specialize

    Abs name body -> do
      t <- fresh (Known typeT)
      define name (var t)
      bodyT <- infer body
      return (var t .->. bodyT)

    App f arg -> do
      ty <- infer f
      case unfix ty of
        Function a b -> do
          check arg a
          return b
        _ -> fail ("Expected a function type, but got " ++ pretty ty)

    -- Types
    UnitT -> return typeT
    TypeT -> return typeT -- Impredicativity.
    Function{} -> isType term >> return typeT
    Product{} -> isType term >> return typeT
    Sum{} -> isType term >> return typeT

  Check term ty -> do
    ty' <- infer term
    unless (ty' == ty) $ fail ("Expected " ++ pretty ty ++ " but got " ++ pretty ty')

  IsType ty -> case unfix ty of
    UnitT -> return ()
    TypeT -> return ()
    Sum a b -> do
      isType a
      isType b
    Product a b -> do
      isType a
      isType b
    Function a b -> do
      isType a
      isType b

    Var name -> do
      ty <- find name >>= specialize
      isType ty

    _ -> fail ("Expected a Type but got " ++ pretty ty)


interpret :: (Name, Context) -> Proof a -> Result a
interpret context proof = case runFreer proof of
  -- Failure s -> Error s
  Pure a -> Result a
  Free cont proof -> case proof of
    J judgement -> interpret context (decompose judgement) >>= interpret context . cont
    S state -> case state of
      Get -> interpret context (cont context)
      Put context' -> interpret context' (cont ())
    R result -> result >>= interpret context . cont


-- Instances

instance Show1 Judgement where
  liftShowsPrec _ _ d judgement = case judgement of
    Check term ty -> showsBinaryWith showsPrec showsPrec "Check" d term ty
    Infer term -> showsUnaryWith showsPrec "Infer" d term

    IsType ty -> showsUnaryWith showsPrec "IsType" d ty
