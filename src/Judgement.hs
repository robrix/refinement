{-# LANGUAGE FlexibleInstances, GADTs, RankNTypes #-}
module Judgement where

import Context hiding (S)
import qualified Context
import Control.Monad hiding (fail)
import Control.Monad.Free.Freer
import Control.State
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

  Unify :: Type -> Type -> Judgement ()

  Fresh :: Declaration -> Judgement Name


class Binder a where
  (<?) :: Name -> a -> Bool
  (<?) name = notElem name . freeVariables

  freeVariables :: a -> [Name]

class Binder1 f where
  liftIn :: (Name -> a -> Bool) -> Name -> f a -> Bool

  liftFreeVariables :: (a -> [Name]) -> f a -> [Name]

instance (Foldable t, Binder a) => Binder (t a) where
  (<?) name = any (name <?)

  freeVariables = foldMap freeVariables

instance Binder Name where
  (<?) = (==)

  freeVariables = (:[])

instance Binder TypeEntry where
  (<?) name (_ := Some t) = name <? t
  _ <? _ = False

  freeVariables (_ := Some t) = freeVariables t
  freeVariables _ = []

instance Binder1 f => Binder (Fix f) where
   (<?) name = liftIn (<?) name . unfix

   freeVariables = liftFreeVariables freeVariables . unfix

instance Binder1 ExprF where
  liftIn isBound name = any (isBound name)

  liftFreeVariables = foldMap


unify :: Type -> Type -> Proof ()
unify t1 t2 = J (Unify t1 t2) `andThen` return

unify' :: Type -> Type -> Proof ()
unify' t1 t2 = case (unfix t1, unfix t2) of
  (Function a1 b1, Function a2 b2) -> unify a1 a2 >> unify b1 b2
  (Product a1 b1, Product a2 b2) -> unify a1 a2 >> unify b1 b2
  (Sum a1 b1, Sum a2 b2) -> unify a1 a2 >> unify b1 b2
  (UnitT, UnitT) -> return ()
  (TypeT, TypeT) -> return ()

  (Abs _ b1, Abs _ b2) -> unify b1 b2 -- this should probably be pushing unknown declarations onto the context
  (Var v1, Var v2) -> onTop $ \ (n := d) ->
    case (n == v1, n == v2, d) of
      (True, True, _) -> restore
      (True, False, Hole) -> replace [ v1 := Some (var v2) ]
      (False, True, Hole) -> replace [ v2 := Some (var v1) ]
      (True, False, Some t) -> unify t2 t >> restore
      (False, True, Some t) -> unify t1 t >> restore
      (False, False, _) -> unify t1 t2 >> restore
  (Var v, _) -> solve v [] t2
  (_, Var v) -> solve v [] t1
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
  case (n == name, n <? ty || n <? suffix, d) of
    (True, True, _) -> fail "Occurs check failed."
    (True, False, Hole) -> replace (suffix ++ [ name := Some ty ])
    (True, False, Some v) -> do
      modifyContext (<>< suffix)
      unify v ty
      restore
    (False, True, _) -> do
      solve name (n := d : suffix) ty
      replace []
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
        unpack (Context.All s') = (Hole, s')
        unpack (LetS t s') = (Some t, s')
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

fresh' :: Declaration -> Proof Name
fresh' d = do
  (m, context) <- get
  put (increment m, context :< Ty (m := d))
  return m
  where increment (Name n) = Name (succ n)

fresh :: Declaration -> Proof Name
fresh declaration = J (Fresh declaration) `andThen` return


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
define name ty = modifyContext (<>< [ name := Some ty ])

find :: Name -> Proof Scheme
find name = getContext >>= help
  where help (_ :< Tm (found `Is` decl))
          | name == found = return decl
        help (context :< _) = help context
        help _ = fail ("Missing variable " ++ pretty name ++ " in context.")


fail :: String -> Proof a
fail = wrap . R . Error . (:[])


(>-) :: TermEntry -> Proof a -> Proof a
x `Is` s >- ma = do
  modifyContext (:< Tm (x `Is` s))
  a <- ma
  modifyContext extract
  return a
  where extract (context :< Tm (y `Is` _)) | x == y = context
        extract (context :< Ty d) = extract context :< Ty d
        extract (_ :< _) = error "Bad context entry!"
        extract _ = error "Missing term variable!"


bind :: Name -> Scheme -> Schm (Index Name)
bind a = fmap help
  where help :: Name -> Index Name
        help b | a == b = Z
               | otherwise = Context.S b

(==>) :: Suffix -> Type -> Scheme
[]                     ==> ty = Type ty
((a := Hole) : rest)   ==> ty = All (bind a (rest ==> ty))
((a := Some v) : rest) ==> ty = LetS v (bind a (rest ==> ty))

generalizeOver :: Proof Type -> Proof Scheme
generalizeOver mt = do
  modifyContext (:< Sep)
  t <- mt
  rest <- skimContext []
  return (rest ==> t)
  where skimContext :: Suffix -> Proof Suffix
        skimContext rest = do
          context :< d <- getContext
          putContext context
          case d of
            Sep -> return rest
            Ty a -> skimContext (a : rest)
            Tm _ -> error "Unexpected term variable."


decompose :: Judgement a -> Proof a
decompose judgement = case judgement of
  Infer term -> case unfix term of
    Pair x y -> do
      a <- infer x
      b <- infer y
      return (a .*. b)

    Fst p -> do
      ty <- infer p
      a <- fresh Hole
      b <- fresh Hole
      unify ty (var a .*. var b)
      return (var a)

    Snd p -> do
      ty <- infer p
      a <- fresh Hole
      b <- fresh Hole
      unify ty (var a .*. var b)
      return (var b)

    InL l -> do
      a <- infer l
      b <- fresh Hole
      return (a .+. var b)

    InR r -> do
      a <- fresh Hole
      b <- infer r
      return (var a .+. b)

    Case subject ifL ifR -> do
      ty <- infer subject
      l <- fresh Hole
      r <- fresh Hole
      unify ty (var l .+. var r)
      b <- fresh Hole
      tl <- infer ifL
      tr <- infer ifR
      unify tl (var l .->. var b)
      unify tr (var r .->. var b)
      return (var b)

    Unit -> return unitT

    Var name -> find name >>= specialize

    Abs name body -> do
      a <- fresh Hole
      v <- name `Is` Type (var a) >- infer body
      return (var a .->. v)

    App f arg -> do
      ty <- infer f
      a <- infer arg
      b <- fresh Hole
      unify ty (a .->. var b)
      return (var b)

    -- Types
    UnitT -> return typeT
    TypeT -> return typeT -- Impredicativity.
    Function{} -> isType term >> return typeT
    Product{} -> isType term >> return typeT
    Sum{} -> isType term >> return typeT

    Let name value body -> do
      t <- generalizeOver (infer value)
      name `Is` t >- infer body

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

  Unify t1 t2 -> unify' t1 t2

  Fresh declaration -> fresh' declaration


run :: (Name, Context) -> Proof a -> Result a
run context proof = case runStep context proof of
  Left result -> result
  Right next -> uncurry run next

runSteps :: (Name, Context) -> Proof a -> [Either (Result a) ((Name, Context), Proof a)]
runSteps context proof = case runStep context proof of
  Left result -> [ Left result ]
  Right next -> Right next : uncurry runSteps next

runStep :: (Name, Context) -> Proof a -> Either (Result a) ((Name, Context), Proof a)
runStep context proof = case runFreer proof of
  Pure a -> Left $ Result a
  Free cont proof -> case proof of
    J judgement -> Right (context, decompose judgement >>= cont)
    S state -> case state of
      Get -> Right (context, cont context)
      Put context' -> Right (context', cont ())
    R result -> case result of
      Error e -> Left (Error e)
      Result a -> Right (context, cont a)


-- Instances

instance Show1 Judgement where
  liftShowsPrec _ _ d judgement = case judgement of
    Check term ty -> showsBinaryWith showsPrec showsPrec "Check" d term ty
    Infer term -> showsUnaryWith showsPrec "Infer" d term

    IsType ty -> showsUnaryWith showsPrec "IsType" d ty

    Unify t1 t2 -> showsBinaryWith showsPrec showsPrec "Unify" d t1 t2

    Fresh declaration -> showsUnaryWith showsPrec "Fresh" d declaration

instance Show a => Show (Judgement a) where
  showsPrec = showsPrec1

instance Show1 ProofF where
  liftShowsPrec sp sl d proof = case proof of
    J judgement -> showsUnaryWith (liftShowsPrec sp sl) "J" d judgement
    S state -> showsUnaryWith (liftShowsPrec sp sl) "S" d state
    R result -> showsUnaryWith (liftShowsPrec sp sl) "R" d result

instance Show a => Show (ProofF a) where
  showsPrec = showsPrec1

instance Pretty1 Judgement where
  liftPrettyPrec _ d judgement = case judgement of
    Check term ty -> showParen (d > 10) $ showsBinaryWith prettyPrec prettyType "check" 10 term ty
    Infer term -> showParen (d > 10) $ showsUnaryWith prettyPrec "infer" 10 term
    IsType ty -> showParen (d > 10) $ showsUnaryWith prettyType "isType" 10 ty
    Unify t1 t2 -> showParen (d > 10) $ showsBinaryWith prettyType prettyType "unify" d t1 t2
    Fresh declaration -> showParen (d > 10) $ showsUnaryWith prettyPrec "fresh" 10 declaration

instance Pretty1 ProofF where
  liftPrettyPrec pp d proof = case proof of
    J judgement -> liftPrettyPrec pp d judgement
    S state -> liftPrettyPrec pp d state
    R result -> liftPrettyPrec pp d result
