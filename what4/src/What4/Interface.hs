{-|
Module           : What4.Interface
Description      : Main interface for constructing What4 formulae
Copyright        : (c) Galois, Inc 2014-2020
License          : BSD3
Maintainer       : Joe Hendrix <jhendrix@galois.com>

Defines interface between the simulator and terms that are sent to the
SAT or SMT solver.  The simulator can use a richer set of types, but the
symbolic values must be representable by types supported by this interface.

A solver backend is defined in terms of a type parameter @sym@, which
is the type that tracks whatever state or context is needed by that
particular backend. To instantiate the solver interface, one must
provide several type family definitions and class instances for @sym@:

  [@type 'SymExpr' sym :: 'BaseType' -> *@]
  Type of symbolic expressions.

  [@type 'BoundVar' sym :: 'BaseType' -> *@]
  Representation of bound variables in symbolic expressions.

  [@type 'SymFn' sym :: Ctx BaseType -> BaseType -> *@]
  Representation of symbolic functions.

  [@instance 'IsExprBuilder' sym@]
  Functions for building expressions of various types.

  [@instance 'IsSymExprBuilder' sym@]
  Functions for building expressions with bound variables and quantifiers.

  [@instance 'IsExpr' ('SymExpr' sym)@]
  Recognizers for various kinds of literal expressions.

  [@instance 'OrdF' ('SymExpr' sym)@]

  [@instance 'TestEquality' ('SymExpr' sym)@]

  [@instance 'HashableF' ('SymExpr' sym)@]

The canonical implementation of these interface classes is found in "What4.Expr.Builder".
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

{-# LANGUAGE UndecidableInstances #-}

module What4.Interface
  ( -- * Interface classes
    -- ** Type Families
    SymExpr
  , BoundVar
  , SymFn
  , SymAnnotation

    -- ** Expression recognizers
  , IsExpr(..)
  , IsSymFn(..)
  , UnfoldPolicy(..)
  , shouldUnfold

    -- ** IsExprBuilder
  , IsExprBuilder(..)
  , IsSymExprBuilder(..)
  , SolverEvent(..)
  , SolverStartSATQuery(..)
  , SolverEndSATQuery(..)

    -- ** Bitvector operations
  , bvJoinVector
  , bvSplitVector
  , bvSwap
  , bvBitreverse

    -- ** Floating-point rounding modes
  , RoundingMode(..)

    -- ** Run-time statistics
  , Statistics(..)
  , zeroStatistics

    -- * Type Aliases
  , Pred
  , SymInteger
  , SymReal
  , SymFloat
  , SymString
  , SymCplx
  , SymStruct
  , SymBV
  , SymArray

    -- * Natural numbers
  , SymNat
  , asNat
  , natLit
  , natAdd
  , natSub
  , natMul
  , natDiv
  , natMod
  , natIte
  , natEq
  , natLe
  , natLt
  , natToInteger
  , bvToNat
  , natToReal
  , integerToNat
  , realToNat
  , freshBoundedNat
  , freshNat
  , printSymNat

    -- * Array utility types
  , IndexLit(..)
  , indexLit
  , ArrayResultWrapper(..)

    -- * Concrete values
  , asConcrete
  , concreteToSym
  , baseIsConcrete
  , baseDefaultValue
  , realExprAsInteger
  , rationalAsInteger
  , cplxExprAsRational
  , cplxExprAsInteger

    -- * SymEncoder
  , SymEncoder(..)

    -- * Utility combinators
    -- ** Boolean operations
  , backendPred
  , andAllOf
  , orOneOf
  , itePredM
  , iteM
  , iteList
  , predToReal

    -- ** Complex number operations
  , cplxDiv
  , cplxLog
  , cplxLogBase
  , mkRational
  , mkReal
  , isNonZero
  , isReal

    -- ** Indexing
  , muxRange

    -- * Exceptions
  , InvalidRange(..)

    -- * Reexports
  , module Data.Parameterized.NatRepr
  , module What4.BaseTypes
  , HasAbsValue
  , What4.Symbol.SolverSymbol
  , What4.Symbol.emptySymbol
  , What4.Symbol.userSymbol
  , What4.Symbol.safeSymbol
  , ValueRange(..)
  , StringLiteral(..)
  , stringLiteralInfo
  ) where

#if !MIN_VERSION_base(4,13,0)
import Control.Monad.Fail( MonadFail )
#endif

import           Control.Exception (assert, Exception)
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.BitVector.Sized as BV
import           Data.Coerce (coerce)
import           Data.Foldable
import           Data.Kind ( Type )
import qualified Data.Map as Map
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Ctx
import           Data.Parameterized.Utils.Endian (Endian(..))
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TraversableFC
import qualified Data.Parameterized.Vector as Vector
import           Data.Ratio
import           Data.Scientific (Scientific)
import           Data.Set (Set)
import           GHC.Generics (Generic)
import           Numeric.Natural
import           LibBF (BigFloat)
import           Prettyprinter (Doc)

import           What4.BaseTypes
import           What4.Config
import qualified What4.Expr.ArrayUpdateMap as AUM
import           What4.IndexLit
import           What4.ProgramLoc
import           What4.Concrete
import           What4.SatResult
import           What4.SpecialFunctions
import           What4.Symbol
import           What4.Utils.AbstractDomains
import           What4.Utils.Arithmetic
import           What4.Utils.Complex
import           What4.Utils.FloatHelpers (RoundingMode(..))
import           What4.Utils.StringLiteral

------------------------------------------------------------------------
-- SymExpr names

-- | Symbolic boolean values, AKA predicates.
type Pred sym = SymExpr sym BaseBoolType

-- | Symbolic integers.
type SymInteger sym = SymExpr sym BaseIntegerType

-- | Symbolic real numbers.
type SymReal sym = SymExpr sym BaseRealType

-- | Symbolic floating point numbers.
type SymFloat sym fpp = SymExpr sym (BaseFloatType fpp)

-- | Symbolic complex numbers.
type SymCplx sym = SymExpr sym BaseComplexType

-- | Symbolic structures.
type SymStruct sym flds = SymExpr sym (BaseStructType flds)

-- | Symbolic arrays.
type SymArray sym idx b = SymExpr sym (BaseArrayType idx b)

-- | Symbolic bitvectors.
type SymBV sym n = SymExpr sym (BaseBVType n)

-- | Symbolic strings.
type SymString sym si = SymExpr sym (BaseStringType si)

------------------------------------------------------------------------
-- Type families for the interface.

-- | The class for expressions.
type family SymExpr (sym :: Type) :: BaseType -> Type

------------------------------------------------------------------------
-- | Type of bound variable associated with symbolic state.
--
-- This type is used by some methods in class 'IsSymExprBuilder'.
type family BoundVar (sym :: Type) :: BaseType -> Type


------------------------------------------------------------------------
-- | Type used to uniquely identify expressions that have been annotated.
type family SymAnnotation (sym :: Type) :: BaseType -> Type

------------------------------------------------------------------------
-- IsBoolSolver

-- | Perform an ite on a predicate lazily.
itePredM :: (IsExpr (SymExpr sym), IsExprBuilder sym, MonadIO m)
         => sym
         -> Pred sym
         -> m (Pred sym)
         -> m (Pred sym)
         -> m (Pred sym)
itePredM sym c mx my =
  case asConstantPred c of
    Just True -> mx
    Just False -> my
    Nothing -> do
      x <- mx
      y <- my
      liftIO $ itePred sym c x y

------------------------------------------------------------------------
-- IsExpr

-- | This class provides operations for recognizing when symbolic expressions
--   represent concrete values, extracting the type from an expression,
--   and for providing pretty-printed representations of an expression.
class HasAbsValue e => IsExpr e where
  -- | Evaluate if predicate is constant.
  asConstantPred :: e BaseBoolType -> Maybe Bool
  asConstantPred _ = Nothing

  -- | Return integer if this is a constant integer.
  asInteger :: e BaseIntegerType -> Maybe Integer
  asInteger _ = Nothing

  -- | Return any bounding information we have about the term
  integerBounds :: e BaseIntegerType -> ValueRange Integer

  -- | Return rational if this is a constant value.
  asRational :: e BaseRealType -> Maybe Rational
  asRational _ = Nothing

  -- | Return floating-point value if this is a constant
  asFloat :: e (BaseFloatType fpp) -> Maybe BigFloat

  -- | Return any bounding information we have about the term
  rationalBounds :: e BaseRealType -> ValueRange Rational

  -- | Return complex if this is a constant value.
  asComplex :: e BaseComplexType -> Maybe (Complex Rational)
  asComplex _ = Nothing

  -- | Return a bitvector if this is a constant bitvector.
  asBV :: e (BaseBVType w) -> Maybe (BV.BV w)
  asBV _ = Nothing

  -- | If we have bounds information about the term, return unsigned
  -- upper and lower bounds as integers
  unsignedBVBounds :: (1 <= w) => e (BaseBVType w) -> Maybe (Integer, Integer)

  -- | If we have bounds information about the term, return signed
  -- upper and lower bounds as integers
  signedBVBounds :: (1 <= w) => e (BaseBVType w) -> Maybe (Integer, Integer)

  -- | If this expression syntactically represents an "affine" form, return its components.
  --   When @asAffineVar x = Just (c,r,o)@, then we have @x == c*r + o@.
  asAffineVar :: e tp -> Maybe (ConcreteVal tp, e tp, ConcreteVal tp)

  -- | Return the string value if this is a constant string
  asString :: e (BaseStringType si) -> Maybe (StringLiteral si)
  asString _ = Nothing

  -- | Return the representation of the string info for a string-typed term.
  stringInfo :: e (BaseStringType si) -> StringInfoRepr si
  stringInfo e =
    case exprType e of
      BaseStringRepr si -> si

  -- | Return the unique element value if this is a constant array,
  --   such as one made with 'constantArray'.
  asConstantArray :: e (BaseArrayType idx bt) -> Maybe (e bt)
  asConstantArray _ = Nothing

  -- | Return the struct fields if this is a concrete struct.
  asStruct :: e (BaseStructType flds) -> Maybe (Ctx.Assignment e flds)
  asStruct _ = Nothing

  -- | Get type of expression.
  exprType :: e tp -> BaseTypeRepr tp

  -- | Get the width of a bitvector
  bvWidth      :: e (BaseBVType w) -> NatRepr w
  bvWidth e =
    case exprType e of
      BaseBVRepr w -> w

  -- | Get the precision of a floating-point expression
  floatPrecision :: e (BaseFloatType fpp) -> FloatPrecisionRepr fpp
  floatPrecision e =
    case exprType e of
      BaseFloatRepr fpp -> fpp

  -- | Print a sym expression for debugging or display purposes.
  printSymExpr :: e tp -> Doc ann

  -- | Set the abstract value of an expression. This is primarily useful for
  -- symbolic expressions where the domain is known to be narrower than what
  -- is contained in the expression. Setting the abstract value to use the
  -- narrower domain can, in some cases, allow the expression to be further
  -- simplified.
  --
  -- This is prefixed with @unsafe-@ because it has the potential to
  -- introduce unsoundness if the new abstract value does not accurately
  -- represent the domain of the expression. As such, the burden is on users
  -- of this function to ensure that the new abstract value is used soundly.
  --
  -- Note that composing expressions together can sometimes widen the abstract
  -- domains involved, so if you use this function to change an abstract value,
  -- be careful than subsequent operations do not widen away the value. As a
  -- potential safeguard, one can use 'annotateTerm' on the new expression to
  -- inhibit transformations that could change the abstract value.
  unsafeSetAbstractValue :: AbstractValue tp -> e tp -> e tp


newtype ArrayResultWrapper f idx tp =
  ArrayResultWrapper { unwrapArrayResult :: f (BaseArrayType idx tp) }

instance TestEquality f => TestEquality (ArrayResultWrapper f idx) where
  testEquality (ArrayResultWrapper x) (ArrayResultWrapper y) = do
    Refl <- testEquality x y
    return Refl

instance HashableF e => HashableF (ArrayResultWrapper e idx) where
  hashWithSaltF s (ArrayResultWrapper v) = hashWithSaltF s v


-- | This datatype describes events that involve interacting with
--   solvers.  A @SolverEvent@ will be provided to the action
--   installed via @setSolverLogListener@ whenever an interesting
--   event occurs.
data SolverEvent
  = SolverStartSATQuery SolverStartSATQuery
  | SolverEndSATQuery SolverEndSATQuery
 deriving (Show, Generic)

data SolverStartSATQuery = SolverStartSATQueryRec
    { satQuerySolverName :: !String
    , satQueryReason     :: !String
    }
 deriving (Show, Generic)

data SolverEndSATQuery = SolverEndSATQueryRec
    { satQueryResult     :: !(SatResult () ())
    , satQueryError      :: !(Maybe String)
    }
 deriving (Show, Generic)

------------------------------------------------------------------------
-- SymNat

-- | Symbolic natural numbers.
newtype SymNat sym =
  SymNat
  { -- Internal Invariant: the value in a SymNat is always nonnegative
    _symNat :: SymExpr sym BaseIntegerType
  }

-- | Return nat if this is a constant natural number.
asNat :: IsExpr (SymExpr sym) => SymNat sym -> Maybe Natural
asNat (SymNat x) = fromInteger . max 0 <$> asInteger x

-- | A natural number literal.
natLit :: IsExprBuilder sym => sym -> Natural -> IO (SymNat sym)
-- @Natural@ input is necessarily nonnegative
natLit sym x = SymNat <$> intLit sym (toInteger x)

-- | Add two natural numbers.
natAdd :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
-- Integer addition preserves nonnegative values
natAdd sym (SymNat x) (SymNat y) = SymNat <$> intAdd sym x y

-- | Subtract one number from another.
--
-- The result is 0 if the subtraction would otherwise be negative.
natSub :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
natSub sym (SymNat x) (SymNat y) =
  do z <- intSub sym x y
     SymNat <$> (intMax sym z =<< intLit sym 0)

-- | Multiply one number by another.
natMul :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
-- Integer multiplication preserves nonnegative values
natMul sym (SymNat x) (SymNat y) = SymNat <$> intMul sym x y

-- | @'natDiv' sym x y@ performs division on naturals.
--
-- The result is undefined if @y@ equals @0@.
--
-- 'natDiv' and 'natMod' satisfy the property that given
--
-- @
--   d <- natDiv sym x y
--   m <- natMod sym x y
-- @
--
--  and @y > 0@, we have that @y * d + m = x@ and @m < y@.
natDiv :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
-- Integer division preserves nonnegative values.
natDiv sym (SymNat x) (SymNat y) = SymNat <$> intDiv sym x y

-- | @'natMod' sym x y@ returns @x@ mod @y@.
--
-- See 'natDiv' for a description of the properties the return
-- value is expected to satisfy.
natMod :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
-- Integer modulus preserves nonnegative values.
natMod sym (SymNat x) (SymNat y) = SymNat <$> intMod sym x y

-- | If-then-else applied to natural numbers.
natIte :: IsExprBuilder sym => sym -> Pred sym -> SymNat sym -> SymNat sym -> IO (SymNat sym)
-- ITE preserves nonnegative values.
natIte sym p (SymNat x) (SymNat y) = SymNat <$> intIte sym p x y

-- | Equality predicate for natural numbers.
natEq :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (Pred sym)
natEq sym (SymNat x) (SymNat y) = intEq sym x y

-- | @'natLe' sym x y@ returns @true@ if @x <= y@.
natLe :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (Pred sym)
natLe sym (SymNat x) (SymNat y) = intLe sym x y

-- | @'natLt' sym x y@ returns @true@ if @x < y@.
natLt :: IsExprBuilder sym => sym -> SymNat sym -> SymNat sym -> IO (Pred sym)
natLt sym x y = notPred sym =<< natLe sym y x

-- | Convert a natural number to an integer.
natToInteger :: IsExprBuilder sym => sym -> SymNat sym -> IO (SymInteger sym)
natToInteger _sym (SymNat x) = pure x

-- | Convert the unsigned value of a bitvector to a natural.
bvToNat :: (IsExprBuilder sym, 1 <= w) => sym -> SymBV sym w -> IO (SymNat sym)
-- The unsigned value of a bitvector is always nonnegative
bvToNat sym x = SymNat <$> bvToInteger sym x

-- | Convert a natural number to a real number.
natToReal :: IsExprBuilder sym => sym -> SymNat sym -> IO (SymReal sym)
natToReal sym = natToInteger sym >=> integerToReal sym

-- | Convert an integer to a natural number.
--
-- For negative integers, the result is clamped to 0.
integerToNat :: IsExprBuilder sym => sym -> SymInteger sym -> IO (SymNat sym)
integerToNat sym x = SymNat <$> (intMax sym x =<< intLit sym 0)

-- | Convert a real number to a natural number.
--
-- The result is undefined if the given real number does not represent a natural number.
realToNat :: IsExprBuilder sym => sym -> SymReal sym -> IO (SymNat sym)
realToNat sym r = realToInteger sym r >>= integerToNat sym

-- | Create a fresh natural number constant with optional lower and upper bounds.
--   If provided, the bounds are inclusive.
--   If inconsistent bounds are given, an InvalidRange exception will be thrown.
freshBoundedNat ::
  IsSymExprBuilder sym =>
  sym ->
  SolverSymbol ->
  Maybe Natural {- ^ lower bound -} ->
  Maybe Natural {- ^ upper bound -} ->
  IO (SymNat sym)
freshBoundedNat sym s lo hi = SymNat <$> (freshBoundedInt sym s lo' hi')
 where
   lo' = Just (maybe 0 toInteger lo)
   hi' = toInteger <$> hi

-- | Create a fresh natural number constant.
freshNat :: IsSymExprBuilder sym => sym -> SolverSymbol -> IO (SymNat sym)
freshNat sym s = freshBoundedNat sym s (Just 0) Nothing

printSymNat :: IsExpr (SymExpr sym) => SymNat sym -> Doc ann
printSymNat (SymNat x) = printSymExpr x

instance TestEquality (SymExpr sym) => Eq (SymNat sym) where
  SymNat x == SymNat y = isJust (testEquality x y)

instance OrdF (SymExpr sym) => Ord (SymNat sym) where
  compare (SymNat x) (SymNat y) = toOrdering (compareF x y)

instance (HashableF (SymExpr sym), TestEquality (SymExpr sym)) => Hashable (SymNat sym) where
  hashWithSalt s (SymNat x) = hashWithSaltF s x

------------------------------------------------------------------------
-- IsExprBuilder

-- | This class allows the simulator to build symbolic expressions.
--
-- Methods of this class refer to type families @'SymExpr' sym@
-- and @'SymFn' sym@.
--
-- Note: Some methods in this class represent operations that are
-- partial functions on their domain (e.g., division by 0).
-- Such functions will have documentation strings indicating that they
-- are undefined under some conditions.  When partial functions are applied
-- outside their defined domains, they will silently produce an unspecified
-- value of the expected type.  The unspecified value returned as the result
-- of an undefined function is _not_ guaranteed to be equivalant to a free
-- constant, and no guarantees are made about what properties such values
-- will satisfy.
class ( IsExpr (SymExpr sym), HashableF (SymExpr sym)
      , TestEquality (SymAnnotation sym), OrdF (SymAnnotation sym)
      , HashableF (SymAnnotation sym)
      ) => IsExprBuilder sym where

  -- | Retrieve the configuration object corresponding to this solver interface.
  getConfiguration :: sym -> Config


  -- | Install an action that will be invoked before and after calls to
  --   backend solvers.  This action is primarily intended to be used for
  --   logging\/profiling\/debugging purposes.  Passing 'Nothing' to this
  --   function disables logging.
  setSolverLogListener :: sym -> Maybe (SolverEvent -> IO ()) -> IO ()

  -- | Get the currently-installed solver log listener, if one has been installed.
  getSolverLogListener :: sym -> IO (Maybe (SolverEvent -> IO ()))

  -- | Provide the given event to the currently installed
  --   solver log listener, if any.
  logSolverEvent :: sym -> SolverEvent -> IO ()

  -- | Get statistics on execution from the initialization of the
  -- symbolic interface to this point.  May return zeros if gathering
  -- statistics isn't supported.
  getStatistics :: sym -> IO Statistics
  getStatistics _ = return zeroStatistics

  ----------------------------------------------------------------------
  -- Program location operations

  -- | Get current location of program for term creation purposes.
  getCurrentProgramLoc :: sym -> IO ProgramLoc

  -- | Set current location of program for term creation purposes.
  setCurrentProgramLoc :: sym -> ProgramLoc -> IO ()

  -- | Return true if two expressions are equal. The default
  -- implementation dispatches 'eqPred', 'bvEq', 'natEq', 'intEq',
  -- 'realEq', 'cplxEq', 'structEq', or 'arrayEq', depending on the
  -- type.
  isEq :: sym -> SymExpr sym tp -> SymExpr sym tp -> IO (Pred sym)
  isEq sym x y =
    case exprType x of
      BaseBoolRepr     -> eqPred sym x y
      BaseBVRepr{}     -> bvEq sym x y
      BaseIntegerRepr  -> intEq sym x y
      BaseRealRepr     -> realEq sym x y
      BaseFloatRepr{}  -> floatEq sym x y
      BaseComplexRepr  -> cplxEq sym x y
      BaseStringRepr{} -> stringEq sym x y
      BaseStructRepr{} -> structEq sym x y
      BaseArrayRepr{}  -> arrayEq sym x y

  -- | Take the if-then-else of two expressions. The default
  -- implementation dispatches 'itePred', 'bvIte', 'natIte', 'intIte',
  -- 'realIte', 'cplxIte', 'structIte', or 'arrayIte', depending on
  -- the type.
  baseTypeIte :: sym
              -> Pred sym
              -> SymExpr sym tp
              -> SymExpr sym tp
              -> IO (SymExpr sym tp)
  baseTypeIte sym c x y =
    case exprType x of
      BaseBoolRepr     -> itePred   sym c x y
      BaseBVRepr{}     -> bvIte     sym c x y
      BaseIntegerRepr  -> intIte    sym c x y
      BaseRealRepr     -> realIte   sym c x y
      BaseFloatRepr{}  -> floatIte  sym c x y
      BaseStringRepr{} -> stringIte sym c x y
      BaseComplexRepr  -> cplxIte   sym c x y
      BaseStructRepr{} -> structIte sym c x y
      BaseArrayRepr{}  -> arrayIte  sym c x y

  -- | Given a symbolic expression, annotate it with a unique identifier
  --   that can be used to maintain a connection with the given term.
  --   The 'SymAnnotation' is intended to be used as the key in a hash
  --   table or map to additional data can be maintained alongside the terms.
  --   The returned 'SymExpr' has the same semantics as the argument, but
  --   has embedded in it the 'SymAnnotation' value so that it can be used
  --   later during term traversals.
  --
  --   Note, the returned annotation is not necessarily fresh; if an
  --   already-annotated term is passed in, the same annotation value will be
  --   returned.
  annotateTerm :: sym -> SymExpr sym tp -> IO (SymAnnotation sym tp, SymExpr sym tp)

  -- | Project an annotation from an expression
  --
  -- It should be the case that using 'getAnnotation' on a term returned by
  -- 'annotateTerm' returns the same annotation that 'annotateTerm' did.
  getAnnotation :: sym -> SymExpr sym tp -> Maybe (SymAnnotation sym tp)

  ----------------------------------------------------------------------
  -- Boolean operations.

  -- | Constant true predicate
  truePred  :: sym -> Pred sym

  -- | Constant false predicate
  falsePred :: sym -> Pred sym

  -- | Boolean negation
  notPred :: sym -> Pred sym -> IO (Pred sym)

  -- | Boolean conjunction
  andPred :: sym -> Pred sym -> Pred sym -> IO (Pred sym)

  -- | Boolean disjunction
  orPred  :: sym -> Pred sym -> Pred sym -> IO (Pred sym)

  -- | Boolean implication
  impliesPred :: sym -> Pred sym -> Pred sym -> IO (Pred sym)
  impliesPred sym x y = do
    nx <- notPred sym x
    orPred sym y nx

  -- | Exclusive-or operation
  xorPred :: sym -> Pred sym -> Pred sym -> IO (Pred sym)

  -- | Equality of boolean values
  eqPred  :: sym -> Pred sym -> Pred sym -> IO (Pred sym)

  -- | If-then-else on a predicate.
  itePred :: sym -> Pred sym -> Pred sym -> Pred sym -> IO (Pred sym)

  ----------------------------------------------------------------------
  -- Integer operations

  -- | Create an integer literal.
  intLit :: sym -> Integer -> IO (SymInteger sym)

  -- | Negate an integer.
  intNeg :: sym -> SymInteger sym -> IO (SymInteger sym)

  -- | Add two integers.
  intAdd :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)

  -- | Subtract one integer from another.
  intSub :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)
  intSub sym x y = intAdd sym x =<< intNeg sym y

  -- | Multiply one integer by another.
  intMul :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)

  -- | Return the minimum value of two integers.
  intMin :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)
  intMin sym x y =
    do p <- intLe sym x y
       intIte sym p x y

  -- | Return the maximum value of two integers.
  intMax :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)
  intMax sym x y =
    do p <- intLe sym x y
       intIte sym p y x

  -- | If-then-else applied to integers.
  intIte :: sym -> Pred sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)

  -- | Integer equality.
  intEq  :: sym -> SymInteger sym -> SymInteger sym -> IO (Pred sym)

  -- | Integer less-than-or-equal.
  intLe  :: sym -> SymInteger sym -> SymInteger sym -> IO (Pred sym)

  -- | Integer less-than.
  intLt  :: sym -> SymInteger sym -> SymInteger sym -> IO (Pred sym)
  intLt sym x y = notPred sym =<< intLe sym y x

  -- | Compute the absolute value of an integer.
  intAbs :: sym -> SymInteger sym -> IO (SymInteger sym)

  -- | @intDiv x y@ computes the integer division of @x@ by @y@.  This division is
  --   interpreted the same way as the SMT-Lib integer theory, which states that
  --   @div@ and @mod@ are the unique Euclidean division operations satisfying the
  --   following for all @y /= 0@:
  --
  --   * @y * (div x y) + (mod x y) == x@
  --   * @ 0 <= mod x y < abs y@
  --
  --   The value of @intDiv x y@ is undefined when @y = 0@.
  --
  --   Integer division requires nonlinear support whenever the divisor is
  --   not a constant.
  --
  --   Note: @div x y@ is @floor (x/y)@ when @y@ is positive
  --   (regardless of sign of @x@) and @ceiling (x/y)@ when @y@ is
  --   negative.  This is neither of the more common "round toward
  --   zero" nor "round toward -inf" definitions.
  --
  --   Some useful theorems that are true of this division/modulus pair:
  --
  --   * @mod x y == mod x (- y) == mod x (abs y)@
  --   * @div x (-y) == -(div x y)@
  intDiv :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)

  -- | @intMod x y@ computes the integer modulus of @x@ by @y@.  See 'intDiv' for
  --   more details.
  --
  --   The value of @intMod x y@ is undefined when @y = 0@.
  --
  --   Integer modulus requires nonlinear support whenever the divisor is
  --   not a constant.
  intMod :: sym -> SymInteger sym -> SymInteger sym -> IO (SymInteger sym)

  -- | @intDivisible x k@ is true whenever @x@ is an integer divisible
  --   by the known natural number @k@.  In other words `divisible x k`
  --   holds if there exists an integer `z` such that `x = k*z`.
  intDivisible :: sym -> SymInteger sym -> Natural -> IO (Pred sym)

  ----------------------------------------------------------------------
  -- Bitvector operations

  -- | Create a bitvector with the given width and value.
  bvLit :: (1 <= w) => sym -> NatRepr w -> BV.BV w -> IO (SymBV sym w)

  -- | Concatenate two bitvectors.
  bvConcat :: (1 <= u, 1 <= v)
           => sym
           -> SymBV sym u  -- ^ most significant bits
           -> SymBV sym v  -- ^ least significant bits
           -> IO (SymBV sym (u+v))

  -- | Select a subsequence from a bitvector.
  bvSelect :: forall idx n w. (1 <= n, idx + n <= w)
           => sym
           -> NatRepr idx  -- ^ Starting index, from 0 as least significant bit
           -> NatRepr n    -- ^ Number of bits to take
           -> SymBV sym w  -- ^ Bitvector to select from
           -> IO (SymBV sym n)

  -- | 2's complement negation.
  bvNeg :: (1 <= w)
        => sym
        -> SymBV sym w
        -> IO (SymBV sym w)

  -- | Add two bitvectors.
  bvAdd :: (1 <= w)
        => sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (SymBV sym w)

  -- | Subtract one bitvector from another.
  bvSub :: (1 <= w)
        => sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (SymBV sym w)
  bvSub sym x y = bvAdd sym x =<< bvNeg sym y

  -- | Multiply one bitvector by another.
  bvMul :: (1 <= w)
        => sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (SymBV sym w)

  -- | Unsigned bitvector division.
  --
  --   The result of @bvUdiv x y@ is undefined when @y@ is zero,
  --   but is otherwise equal to @floor( x / y )@.
  bvUdiv :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (SymBV sym w)

  -- | Unsigned bitvector remainder.
  --
  --   The result of @bvUrem x y@ is undefined when @y@ is zero,
  --   but is otherwise equal to @x - (bvUdiv x y) * y@.
  bvUrem :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (SymBV sym w)

  -- | Signed bitvector division.  The result is truncated to zero.
  --
  --   The result of @bvSdiv x y@ is undefined when @y@ is zero,
  --   but is equal to @floor(x/y)@ when @x@ and @y@ have the same sign,
  --   and equal to @ceiling(x/y)@ when @x@ and @y@ have opposite signs.
  --
  --   NOTE! However, that there is a corner case when dividing @MIN_INT@ by
  --   @-1@, in which case an overflow condition occurs, and the result is instead
  --   @MIN_INT@.
  bvSdiv :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (SymBV sym w)

  -- | Signed bitvector remainder.
  --
  --   The result of @bvSrem x y@ is undefined when @y@ is zero, but is
  --   otherwise equal to @x - (bvSdiv x y) * y@.
  bvSrem :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (SymBV sym w)

  -- | Returns true if the corresponding bit in the bitvector is set.
  testBitBV :: (1 <= w)
            => sym
            -> Natural -- ^ Index of bit (0 is the least significant bit)
            -> SymBV sym w
            -> IO (Pred sym)

  -- | Return true if bitvector is negative.
  bvIsNeg :: (1 <= w) => sym -> SymBV sym w -> IO (Pred sym)
  bvIsNeg sym x = bvSlt sym x =<< bvLit sym (bvWidth x) (BV.zero (bvWidth x))

  -- | If-then-else applied to bitvectors.
  bvIte :: (1 <= w)
        => sym
        -> Pred sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (SymBV sym w)

  -- | Return true if bitvectors are equal.
  bvEq  :: (1 <= w)
        => sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (Pred sym)

  -- | Return true if bitvectors are distinct.
  bvNe  :: (1 <= w)
        => sym
        -> SymBV sym w
        -> SymBV sym w
        -> IO (Pred sym)
  bvNe sym x y = notPred sym =<< bvEq sym x y

  -- | Unsigned less-than.
  bvUlt  :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (Pred sym)

  -- | Unsigned less-than-or-equal.
  bvUle  :: (1 <= w)
         => sym
         -> SymBV sym w
         -> SymBV sym w
         -> IO (Pred sym)
  bvUle sym x y = notPred sym =<< bvUlt sym y x

  -- | Unsigned greater-than-or-equal.
  bvUge :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)
  bvUge sym x y = bvUle sym y x

  -- | Unsigned greater-than.
  bvUgt :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)
  bvUgt sym x y = bvUlt sym y x

  -- | Signed less-than.
  bvSlt :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)

  -- | Signed greater-than.
  bvSgt :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)
  bvSgt sym x y = bvSlt sym y x

  -- | Signed less-than-or-equal.
  bvSle :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)
  bvSle sym x y = notPred sym =<< bvSlt sym y x

  -- | Signed greater-than-or-equal.
  bvSge :: (1 <= w) => sym -> SymBV sym w -> SymBV sym w -> IO (Pred sym)
  bvSge sym x y = notPred sym =<< bvSlt sym x y

  -- | returns true if the given bitvector is non-zero.
  bvIsNonzero :: (1 <= w) => sym -> SymBV sym w -> IO (Pred sym)

  -- | Left shift.  The shift amount is treated as an unsigned value.
  bvShl :: (1 <= w) => sym ->
                       SymBV sym w {- ^ Shift this -} ->
                       SymBV sym w {- ^ Amount to shift by -} ->
                       IO (SymBV sym w)

  -- | Logical right shift.  The shift amount is treated as an unsigned value.
  bvLshr :: (1 <= w) => sym ->
                        SymBV sym w {- ^ Shift this -} ->
                        SymBV sym w {- ^ Amount to shift by -} ->
                        IO (SymBV sym w)

  -- | Arithmetic right shift.  The shift amount is treated as an
  -- unsigned value.
  bvAshr :: (1 <= w) => sym ->
                        SymBV sym w {- ^ Shift this -} ->
                        SymBV sym w {- ^ Amount to shift by -} ->
                        IO (SymBV sym w)

  -- | Rotate left.  The rotate amount is treated as an unsigned value.
  bvRol :: (1 <= w) =>
    sym ->
    SymBV sym w {- ^ bitvector to rotate -} ->
    SymBV sym w {- ^ amount to rotate by -} ->
    IO (SymBV sym w)

  -- | Rotate right.  The rotate amount is treated as an unsigned value.
  bvRor :: (1 <= w) =>
    sym ->
    SymBV sym w {- ^ bitvector to rotate -} ->
    SymBV sym w {- ^ amount to rotate by -} ->
    IO (SymBV sym w)

  -- | Zero-extend a bitvector.
  bvZext :: (1 <= u, u+1 <= r) => sym -> NatRepr r -> SymBV sym u -> IO (SymBV sym r)

  -- | Sign-extend a bitvector.
  bvSext :: (1 <= u, u+1 <= r) => sym -> NatRepr r -> SymBV sym u -> IO (SymBV sym r)

  -- | Truncate a bitvector.
  bvTrunc :: (1 <= r, r+1 <= w) -- Assert result is less than input.
          => sym
          -> NatRepr r
          -> SymBV sym w
          -> IO (SymBV sym r)
  bvTrunc sym w x
    | LeqProof <- leqTrans
        (addIsLeq w (knownNat @1))
        (leqProof (incNat w) (bvWidth x))
    = bvSelect sym (knownNat @0) w x

  -- | Bitwise logical and.
  bvAndBits :: (1 <= w)
            => sym
            -> SymBV sym w
            -> SymBV sym w
            -> IO (SymBV sym w)

  -- | Bitwise logical or.
  bvOrBits  :: (1 <= w)
            => sym
            -> SymBV sym w
            -> SymBV sym w
            -> IO (SymBV sym w)

  -- | Bitwise logical exclusive or.
  bvXorBits :: (1 <= w)
            => sym
            -> SymBV sym w
            -> SymBV sym w
            -> IO (SymBV sym w)

  -- | Bitwise complement.
  bvNotBits :: (1 <= w) => sym -> SymBV sym w -> IO (SymBV sym w)

  -- | @bvSet sym v i p@ returns a bitvector @v'@ where bit @i@ of @v'@ is set to
  -- @p@, and the bits at the other indices are the same as in @v@.
  bvSet :: forall w
         . (1 <= w)
        => sym         -- ^ Symbolic interface
        -> SymBV sym w -- ^ Bitvector to update
        -> Natural     -- ^ 0-based index to set
        -> Pred sym    -- ^ Predicate to set.
        -> IO (SymBV sym w)
  bvSet sym v i p = assert (i < natValue (bvWidth v)) $
    -- NB, this representation based on AND/XOR structure is designed so that a
    -- sequence of bvSet operations will collapse nicely into a xor-linear combination
    -- of the original term and bvFill terms. It has the nice property that we
    -- do not introduce any additional subterm sharing.
    do let w    = bvWidth v
       let mask = BV.bit' w i
       pbits <- bvFill sym w p
       vbits <- bvAndBits sym v =<< bvLit sym w (BV.complement w mask)
       bvXorBits sym vbits =<< bvAndBits sym pbits =<< bvLit sym w mask

  -- | @bvFill sym w p@ returns a bitvector @w@-bits long where every bit
  --   is given by the boolean value of @p@.
  bvFill :: forall w. (1 <= w) =>
    sym       {-^ symbolic interface -} ->
    NatRepr w {-^ output bitvector width -} ->
    Pred sym  {-^ predicate to fill the bitvector with -} ->
    IO (SymBV sym w)

  -- | Return the bitvector of the desired width with all 0 bits;
  --   this is the minimum unsigned integer.
  minUnsignedBV :: (1 <= w) => sym -> NatRepr w -> IO (SymBV sym w)
  minUnsignedBV sym w = bvLit sym w (BV.zero w)

  -- | Return the bitvector of the desired width with all bits set;
  --   this is the maximum unsigned integer.
  maxUnsignedBV :: (1 <= w) => sym -> NatRepr w -> IO (SymBV sym w)
  maxUnsignedBV sym w = bvLit sym w (BV.maxUnsigned w)

  -- | Return the bitvector representing the largest 2's complement
  --   signed integer of the given width.  This consists of all bits
  --   set except the MSB.
  maxSignedBV :: (1 <= w) => sym -> NatRepr w -> IO (SymBV sym w)
  maxSignedBV sym w = bvLit sym w (BV.maxSigned w)

  -- | Return the bitvector representing the smallest 2's complement
  --   signed integer of the given width. This consists of all 0 bits
  --   except the MSB, which is set.
  minSignedBV :: (1 <= w) => sym -> NatRepr w -> IO (SymBV sym w)
  minSignedBV sym w = bvLit sym w (BV.minSigned w)

  -- | Return the number of 1 bits in the input.
  bvPopcount :: (1 <= w) => sym -> SymBV sym w -> IO (SymBV sym w)

  -- | Return the number of consecutive 0 bits in the input, starting from
  --   the most significant bit position.  If the input is zero, all bits are counted
  --   as leading.
  bvCountLeadingZeros :: (1 <= w) => sym -> SymBV sym w -> IO (SymBV sym w)

  -- | Return the number of consecutive 0 bits in the input, starting from
  --   the least significant bit position.  If the input is zero, all bits are counted
  --   as leading.
  bvCountTrailingZeros :: (1 <= w) => sym -> SymBV sym w -> IO (SymBV sym w)

  -- | Unsigned add with overflow bit.
  addUnsignedOF :: (1 <= w)
                => sym
                -> SymBV sym w
                -> SymBV sym w
                -> IO (Pred sym, SymBV sym w)
  addUnsignedOF sym x y = do
    -- Compute result
    r   <- bvAdd sym x y
    -- Return that this overflows if r is less than either x or y
    ovx  <- bvUlt sym r x
    ovy  <- bvUlt sym r y
    ov   <- orPred sym ovx ovy
    return (ov, r)

  -- | Signed add with overflow bit. Overflow is true if positive +
  -- positive = negative, or if negative + negative = positive.
  addSignedOF :: (1 <= w)
              => sym
              -> SymBV sym w
              -> SymBV sym w
              -> IO (Pred sym, SymBV sym w)
  addSignedOF sym x y = do
    xy  <- bvAdd sym x y
    sx  <- bvIsNeg sym x
    sy  <- bvIsNeg sym y
    sxy <- bvIsNeg sym xy

    not_sx  <- notPred sym sx
    not_sy  <- notPred sym sy
    not_sxy <- notPred sym sxy

    -- Return this overflowed if the sign bits of sx and sy are equal,
    -- but different from sxy.
    ov1 <- andPred sym not_sxy =<< andPred sym sx sy
    ov2 <- andPred sym sxy =<< andPred sym not_sx not_sy

    ov  <- orPred sym ov1 ov2
    return (ov, xy)

  -- | Unsigned subtract with overflow bit. Overflow is true if x < y.
  subUnsignedOF ::
    (1 <= w) =>
    sym ->
    SymBV sym w ->
    SymBV sym w ->
    IO (Pred sym, SymBV sym w)
  subUnsignedOF sym x y = do
    xy <- bvSub sym x y
    ov <- bvUlt sym x y
    return (ov, xy)

  -- | Signed subtract with overflow bit. Overflow is true if positive
  -- - negative = negative, or if negative - positive = positive.
  subSignedOF :: (1 <= w)
              => sym
              -> SymBV sym w
              -> SymBV sym w
              -> IO (Pred sym, SymBV sym w)
  subSignedOF sym x y = do
       xy  <- bvSub sym x y
       sx  <- bvIsNeg sym x
       sy  <- bvIsNeg sym y
       sxy <- bvIsNeg sym xy
       ov  <- join (pure (andPred sym) <*> xorPred sym sx sxy <*> xorPred sym sx sy)
       return (ov, xy)


  -- | Compute the carry-less multiply of the two input bitvectors.
  --   This operation is essentially the same as a standard multiply, except that
  --   the partial addends are simply XOR'd together instead of using a standard
  --   adder.  This operation is useful for computing on GF(2^n) polynomials.
  carrylessMultiply ::
    (1 <= w) =>
    sym ->
    SymBV sym w ->
    SymBV sym w ->
    IO (SymBV sym (w+w))
  carrylessMultiply sym x0 y0
    | Just _  <- BV.asUnsigned <$> asBV x0
    , Nothing <- BV.asUnsigned <$> asBV y0
    = go y0 x0
    | otherwise
    = go x0 y0
   where
   go :: (1 <= w) => SymBV sym w -> SymBV sym w -> IO (SymBV sym (w+w))
   go x y =
    do let w = bvWidth x
       let w2 = addNat w w
       -- 1 <= w
       one_leq_w@LeqProof <- return (leqProof (knownNat @1) w)
       -- 1 <= w implies 1 <= w + w
       LeqProof <- return (leqAdd one_leq_w w)
       -- w <= w
       w_leq_w@LeqProof <- return (leqProof w w)
       -- w <= w, 1 <= w implies w + 1 <= w + w
       LeqProof <- return (leqAdd2 w_leq_w one_leq_w)
       z  <- bvLit sym w2 (BV.zero w2)
       x' <- bvZext sym w2 x
       xs <- sequence [ do p <- testBitBV sym (BV.asNatural i) y
                           iteM bvIte sym
                             p
                             (bvShl sym x' =<< bvLit sym w2 i)
                             (return z)
                      | i <- BV.enumFromToUnsigned (BV.zero w2) (BV.mkBV w2 (intValue w - 1))
                      ]
       foldM (bvXorBits sym) z xs

  -- | @unsignedWideMultiplyBV sym x y@ multiplies two unsigned 'w' bit numbers 'x' and 'y'.
  --
  -- It returns a pair containing the top 'w' bits as the first element, and the
  -- lower 'w' bits as the second element.
  unsignedWideMultiplyBV :: (1 <= w)
                         => sym
                         -> SymBV sym w
                         -> SymBV sym w
                         -> IO (SymBV sym w, SymBV sym w)
  unsignedWideMultiplyBV sym x y = do
       let w = bvWidth x
       let dbl_w = addNat w w
       -- 1 <= w
       one_leq_w@LeqProof <- return (leqProof (knownNat @1) w)
       -- 1 <= w implies 1 <= w + w
       LeqProof <- return (leqAdd one_leq_w w)
       -- w <= w
       w_leq_w@LeqProof <- return (leqProof w w)
       -- w <= w, 1 <= w implies w + 1 <= w + w
       LeqProof <- return (leqAdd2 w_leq_w one_leq_w)
       x'  <- bvZext sym dbl_w x
       y'  <- bvZext sym dbl_w y
       s   <- bvMul sym x' y'
       lo  <- bvTrunc sym w s
       n   <- bvLit sym dbl_w (BV.zext dbl_w (BV.width w))
       hi  <- bvTrunc sym w =<< bvLshr sym s n
       return (hi, lo)

  -- | Compute the unsigned multiply of two values with overflow bit.
  mulUnsignedOF ::
    (1 <= w) =>
    sym ->
    SymBV sym w ->
    SymBV sym w ->
    IO (Pred sym, SymBV sym w)
  mulUnsignedOF sym x y =
    do let w = bvWidth x
       let dbl_w = addNat w w
       -- 1 <= w
       one_leq_w@LeqProof <- return (leqProof (knownNat @1) w)
       -- 1 <= w implies 1 <= w + w
       LeqProof <- return (leqAdd one_leq_w w)
       -- w <= w
       w_leq_w@LeqProof <- return (leqProof w w)
       -- w <= w, 1 <= w implies w + 1 <= w + w
       LeqProof <- return (leqAdd2 w_leq_w one_leq_w)
       x'  <- bvZext sym dbl_w x
       y'  <- bvZext sym dbl_w y
       s   <- bvMul sym x' y'
       lo  <- bvTrunc sym w s

       -- overflow if the result is greater than the max representable value in w bits
       ov  <- bvUgt sym s =<< bvLit sym dbl_w (BV.zext dbl_w (BV.maxUnsigned w))

       return (ov, lo)

  -- | @signedWideMultiplyBV sym x y@ multiplies two signed 'w' bit numbers 'x' and 'y'.
  --
  -- It returns a pair containing the top 'w' bits as the first element, and the
  -- lower 'w' bits as the second element.
  signedWideMultiplyBV :: (1 <= w)
                       => sym
                       -> SymBV sym w
                       -> SymBV sym w
                       -> IO (SymBV sym w, SymBV sym w)
  signedWideMultiplyBV sym x y = do
       let w = bvWidth x
       let dbl_w = addNat w w
       -- 1 <= w
       one_leq_w@LeqProof <- return (leqProof (knownNat @1) w)
       -- 1 <= w implies 1 <= w + w
       LeqProof <- return (leqAdd one_leq_w w)
       -- w <= w
       w_leq_w@LeqProof <- return (leqProof w w)
       -- w <= w, 1 <= w implies w + 1 <= w + w
       LeqProof <- return (leqAdd2 w_leq_w one_leq_w)
       x'  <- bvSext sym dbl_w x
       y'  <- bvSext sym dbl_w y
       s   <- bvMul sym x' y'
       lo  <- bvTrunc sym w s
       n   <- bvLit sym dbl_w (BV.zext dbl_w (BV.width w))
       hi  <- bvTrunc sym w =<< bvLshr sym s n
       return (hi, lo)

  -- | Compute the signed multiply of two values with overflow bit.
  mulSignedOF ::
    (1 <= w) =>
    sym ->
    SymBV sym w ->
    SymBV sym w ->
    IO (Pred sym, SymBV sym w)
  mulSignedOF sym x y =
    do let w = bvWidth x
       let dbl_w = addNat w w
       -- 1 <= w
       one_leq_w@LeqProof <- return (leqProof (knownNat @1) w)
       -- 1 <= w implies 1 <= w + w
       LeqProof <- return (leqAdd one_leq_w w)
       -- w <= w
       w_leq_w@LeqProof <- return (leqProof w w)
       -- w <= w, 1 <= w implies w + 1 <= w + w
       LeqProof <- return (leqAdd2 w_leq_w one_leq_w)
       x'  <- bvSext sym dbl_w x
       y'  <- bvSext sym dbl_w y
       s   <- bvMul sym x' y'
       lo  <- bvTrunc sym w s

       -- overflow if greater or less than max representable values
       ov1 <- bvSlt sym s =<< bvLit sym dbl_w (BV.sext w dbl_w (BV.minSigned w))
       ov2 <- bvSgt sym s =<< bvLit sym dbl_w (BV.sext w dbl_w (BV.maxSigned w))
       ov  <- orPred sym ov1 ov2
       return (ov, lo)

  ----------------------------------------------------------------------
  -- Struct operations

  -- | Create a struct from an assignment of expressions.
  mkStruct :: sym
           -> Ctx.Assignment (SymExpr sym) flds
           -> IO (SymStruct sym flds)

  -- | Get the value of a specific field in a struct.
  structField :: sym
              -> SymStruct sym flds
              -> Ctx.Index flds tp
              -> IO (SymExpr sym tp)

  -- | Check if two structs are equal.
  structEq  :: forall flds
            .  sym
            -> SymStruct sym flds
            -> SymStruct sym flds
            -> IO (Pred sym)
  structEq sym x y = do
    case exprType x of
      BaseStructRepr fld_types -> do
        let sz = Ctx.size fld_types
        -- Checks to see if the ith struct fields are equal, and all previous entries
        -- are as well.
        let f :: IO (Pred sym) -> Ctx.Index flds tp -> IO (Pred sym)
            f mp i = do
              xi <- structField sym x i
              yi <- structField sym y i
              i_eq <- isEq sym xi yi
              case asConstantPred i_eq of
                Just True -> mp
                Just False -> return (falsePred sym)
                _ ->  andPred sym i_eq =<< mp
        Ctx.forIndex sz f (return (truePred sym))

  -- | Take the if-then-else of two structures.
  structIte :: sym
            -> Pred sym
            -> SymStruct sym flds
            -> SymStruct sym flds
            -> IO (SymStruct sym flds)

  -----------------------------------------------------------------------
  -- Array operations

  -- | Create an array where each element has the same value.
  constantArray :: sym -- Interface
                -> Ctx.Assignment BaseTypeRepr (idx::>tp) -- ^ Index type
                -> SymExpr sym b -- ^ Constant
                -> IO (SymArray sym (idx::>tp) b)

  -- | Create an array from an arbitrary symbolic function.
  --
  -- Arrays created this way can typically not be compared
  -- for equality when provided to backend solvers.
  arrayFromFn :: sym
              -> SymFn sym (idx ::> itp) ret
              -> IO (SymArray sym (idx ::> itp) ret)

  -- | Create an array by mapping a function over one or more existing arrays.
  arrayMap :: sym
           -> SymFn sym (ctx::>d) r
           -> Ctx.Assignment (ArrayResultWrapper (SymExpr sym) (idx ::> itp)) (ctx::>d)
           -> IO (SymArray sym (idx ::> itp) r)

  -- | Update an array at a specific location.
  arrayUpdate :: sym
              -> SymArray sym (idx::>tp) b
              -> Ctx.Assignment (SymExpr sym) (idx::>tp)
              -> SymExpr sym b
              -> IO (SymArray sym (idx::>tp) b)

  -- | Return element in array.
  arrayLookup :: sym
              -> SymArray sym (idx::>tp) b
              -> Ctx.Assignment (SymExpr sym) (idx::>tp)
              -> IO (SymExpr sym b)

  -- | Copy elements from the source array to the destination array.
  --
  -- @'arrayCopy' sym dest_arr dest_idx src_arr src_idx len@ copies the elements
  -- from @src_arr@ at indices @[src_idx .. (src_idx + len - 1)]@ into
  -- @dest_arr@ at indices @[dest_idx .. (dest_idx + len - 1)]@.
  --
  -- The result is undefined if either @dest_idx + len@ or @src_idx + len@
  -- wraps around.
  arrayCopy ::
    (1 <= w) =>
    sym ->
    SymArray sym (SingleCtx (BaseBVType w)) a {- ^ @dest_arr@ -}  ->
    SymBV sym w {- ^ @dest_idx@ -} ->
    SymArray sym (SingleCtx (BaseBVType w)) a {- ^ @src_arr@ -} ->
    SymBV sym w {- ^ @src_idx@ -} ->
    SymBV sym w {- ^ @len@ -} ->
    IO (SymArray sym (SingleCtx (BaseBVType w)) a)

  -- | Set elements of the given array.
  --
  -- @'arraySet' sym arr idx val len@ sets the elements of @arr@ at indices
  -- @[idx .. (idx + len - 1)]@ to @val@.
  --
  -- The result is undefined if @idx + len@ wraps around.
  arraySet ::
    (1 <= w) =>
    sym ->
    SymArray sym (SingleCtx (BaseBVType w)) a {- ^ @arr@ -} ->
    SymBV sym w {- ^ @idx@ -} ->
    SymExpr sym a {- ^ @val@ -} ->
    SymBV sym w {- ^ @len@ -} ->
    IO (SymArray sym (SingleCtx (BaseBVType w)) a)

  -- | Check whether the lhs array and rhs array are equal at a range of
  --   indices.
  --
  -- @'arrayRangeEq' sym lhs_arr lhs_idx rhs_arr rhs_idx len@ checks whether the
  -- elements of @lhs_arr@ at indices @[lhs_idx .. (lhs_idx + len - 1)]@ and the
  -- elements of @rhs_arr@ at indices @[rhs_idx .. (rhs_idx + len - 1)]@ are
  -- equal.
  --
  -- The result is undefined if either @lhs_idx + len@ or @rhs_idx + len@
  -- wraps around.
  arrayRangeEq ::
    (1 <= w) =>
    sym ->
    SymArray sym (SingleCtx (BaseBVType w)) a {- ^ @lhs_arr@ -} ->
    SymBV sym w {- ^ @lhs_idx@ -} ->
    SymArray sym (SingleCtx (BaseBVType w)) a {- ^ @rhs_arr@ -} ->
    SymBV sym w {- ^ @rhs_idx@ -} ->
    SymBV sym w {- ^ @len@ -} ->
    IO (Pred sym)

  -- | Create an array from a map of concrete indices to values.
  --
  -- This is implemented, but designed to be overridden for efficiency.
  arrayFromMap :: sym
               -> Ctx.Assignment BaseTypeRepr (idx ::> itp)
                  -- ^ Types for indices
               -> AUM.ArrayUpdateMap (SymExpr sym) (idx ::> itp) tp
                  -- ^ Value for known indices.
               -> SymExpr sym tp
                  -- ^ Value for other entries.
               -> IO (SymArray sym (idx ::> itp) tp)
  arrayFromMap sym idx_tps m default_value = do
    a0 <- constantArray sym idx_tps default_value
    arrayUpdateAtIdxLits sym m a0

  -- | Update an array at specific concrete indices.
  --
  -- This is implemented, but designed to be overriden for efficiency.
  arrayUpdateAtIdxLits :: sym
                       -> AUM.ArrayUpdateMap (SymExpr sym) (idx ::> itp) tp
                       -- ^ Value for known indices.
                       -> SymArray sym (idx ::> itp) tp
                       -- ^ Value for existing array.
                       -> IO (SymArray sym (idx ::> itp) tp)
  arrayUpdateAtIdxLits sym m a0 = do
    let updateAt a (i,v) = do
          idx <-  traverseFC (indexLit sym) i
          arrayUpdate sym a idx v
    foldlM updateAt a0 (AUM.toList m)

  -- | If-then-else applied to arrays.
  arrayIte :: sym
           -> Pred sym
           -> SymArray sym idx b
           -> SymArray sym idx b
           -> IO (SymArray sym idx b)

  -- | Return true if two arrays are equal.
  --
  -- Note that in the backend, arrays do not have a fixed number of elements, so
  -- this equality requires that arrays are equal on all elements.
  arrayEq :: sym
          -> SymArray sym idx b
          -> SymArray sym idx b
          -> IO (Pred sym)

  -- | Return true if all entries in the array are true.
  allTrueEntries :: sym -> SymArray sym idx BaseBoolType -> IO (Pred sym)
  allTrueEntries sym a = do
    case exprType a of
      BaseArrayRepr idx_tps _ ->
        arrayEq sym a =<< constantArray sym idx_tps (truePred sym)

  -- | Return true if the array has the value true at every index satisfying the
  -- given predicate.
  arrayTrueOnEntries
    :: sym
    -> SymFn sym (idx::>itp) BaseBoolType
    -- ^ Predicate that indicates if array should be true.
    -> SymArray sym (idx ::> itp) BaseBoolType
    -> IO (Pred sym)

  ----------------------------------------------------------------------
  -- Lossless (injective) conversions

  -- | Convert an integer to a real number.
  integerToReal :: sym -> SymInteger sym -> IO (SymReal sym)

  -- | Return the unsigned value of the given bitvector as an integer.
  bvToInteger :: (1 <= w) => sym -> SymBV sym w -> IO (SymInteger sym)

  -- | Return the signed value of the given bitvector as an integer.
  sbvToInteger :: (1 <= w) => sym -> SymBV sym w -> IO (SymInteger sym)

  -- | Return @1@ if the predicate is true; @0@ otherwise.
  predToBV :: (1 <= w) => sym -> Pred sym -> NatRepr w -> IO (SymBV sym w)

  ----------------------------------------------------------------------
  -- Lossless combinators

  -- | Convert an unsigned bitvector to a real number.
  uintToReal :: (1 <= w) => sym -> SymBV sym w -> IO (SymReal sym)
  uintToReal sym = bvToInteger sym >=> integerToReal sym

  -- | Convert an signed bitvector to a real number.
  sbvToReal :: (1 <= w) => sym -> SymBV sym w -> IO (SymReal sym)
  sbvToReal sym = sbvToInteger sym >=> integerToReal sym

  ----------------------------------------------------------------------
  -- Lossy (non-injective) conversions

  -- | Round a real number to an integer.
  --
  -- Numbers are rounded to the nearest integer, with rounding away from
  -- zero when two integers are equidistant (e.g., 1.5 rounds to 2).
  realRound :: sym -> SymReal sym -> IO (SymInteger sym)

  -- | Round a real number to an integer.
  --
  -- Numbers are rounded to the nearest integer, with rounding toward
  -- even values when two integers are equidistant (e.g., 2.5 rounds to 2).
  realRoundEven :: sym -> SymReal sym -> IO (SymInteger sym)

  -- | Round down to the nearest integer that is at most this value.
  realFloor :: sym -> SymReal sym -> IO (SymInteger sym)

  -- | Round up to the nearest integer that is at least this value.
  realCeil :: sym -> SymReal sym -> IO (SymInteger sym)

  -- | Round toward zero.  This is @floor(x)@ when x is positive
  --   and @celing(x)@ when @x@ is negative.
  realTrunc :: sym -> SymReal sym -> IO (SymInteger sym)
  realTrunc sym x =
    do pneg <- realLt sym x =<< realLit sym 0
       iteM intIte sym pneg (realCeil sym x) (realFloor sym x)

  -- | Convert an integer to a bitvector.  The result is the unique bitvector
  --   whose value (signed or unsigned) is congruent to the input integer, modulo @2^w@.
  --
  --   This operation has the following properties:
  --
  --   *  @bvToInteger (integerToBv x w) == mod x (2^w)@
  --   *  @bvToInteger (integerToBV x w) == x@     when @0 <= x < 2^w@.
  --   *  @sbvToInteger (integerToBV x w) == mod (x + 2^(w-1)) (2^w) - 2^(w-1)@
  --   *  @sbvToInteger (integerToBV x w) == x@    when @-2^(w-1) <= x < 2^(w-1)@
  --   *  @integerToBV (bvToInteger y) w == y@     when @y@ is a @SymBV sym w@
  --   *  @integerToBV (sbvToInteger y) w == y@    when @y@ is a @SymBV sym w@
  integerToBV :: (1 <= w) => sym -> SymInteger sym -> NatRepr w -> IO (SymBV sym w)

  ----------------------------------------------------------------------
  -- Lossy (non-injective) combinators

  -- | Convert a real number to an integer.
  --
  -- The result is undefined if the given real number does not represent an integer.
  realToInteger :: sym -> SymReal sym -> IO (SymInteger sym)

  -- | Convert a real number to an unsigned bitvector.
  --
  -- Numbers are rounded to the nearest representable number, with rounding away from
  -- zero when two integers are equidistant (e.g., 1.5 rounds to 2).
  -- When the real is negative the result is zero.
  realToBV :: (1 <= w) => sym -> SymReal sym -> NatRepr w -> IO (SymBV sym w)
  realToBV sym r w = do
    i <- realRound sym r
    clampedIntToBV sym i w

  -- | Convert a real number to a signed bitvector.
  --
  -- Numbers are rounded to the nearest representable number, with rounding away from
  -- zero when two integers are equidistant (e.g., 1.5 rounds to 2).
  realToSBV  :: (1 <= w) => sym -> SymReal sym -> NatRepr w -> IO (SymBV sym w)
  realToSBV sym r w  = do
    i <- realRound sym r
    clampedIntToSBV sym i w

  -- | Convert an integer to the nearest signed bitvector.
  --
  -- Numbers are rounded to the nearest representable number.
  clampedIntToSBV :: (1 <= w) => sym -> SymInteger sym -> NatRepr w -> IO (SymBV sym w)
  clampedIntToSBV sym i w
    | Just v <- asInteger i = do
      bvLit sym w $ BV.signedClamp w v
    | otherwise = do
      -- Handle case where i < minSigned w
      let min_val = minSigned w
          min_val_bv = BV.minSigned w
      min_sym <- intLit sym min_val
      is_lt <- intLt sym i min_sym
      iteM bvIte sym is_lt (bvLit sym w min_val_bv) $ do
        -- Handle case where i > maxSigned w
        let max_val = maxSigned w
            max_val_bv = BV.maxSigned w
        max_sym <- intLit sym max_val
        is_gt <- intLt sym max_sym i
        iteM bvIte sym is_gt (bvLit sym w max_val_bv) $ do
          -- Do unclamped conversion.
          integerToBV sym i w

  -- | Convert an integer to the nearest unsigned bitvector.
  --
  -- Numbers are rounded to the nearest representable number.
  clampedIntToBV :: (1 <= w) => sym -> SymInteger sym -> NatRepr w -> IO (SymBV sym w)
  clampedIntToBV sym i w
    | Just v <- asInteger i = do
      bvLit sym w $ BV.unsignedClamp w v
    | otherwise = do
      -- Handle case where i < 0
      min_sym <- intLit sym 0
      is_lt <- intLt sym i min_sym
      iteM bvIte sym is_lt (bvLit sym w (BV.zero w)) $ do
        -- Handle case where i > maxUnsigned w
        let max_val = maxUnsigned w
            max_val_bv = BV.maxUnsigned w
        max_sym <- intLit sym max_val
        is_gt <- intLt sym max_sym i
        iteM bvIte sym is_gt (bvLit sym w max_val_bv) $
          -- Do unclamped conversion.
          integerToBV sym i w

  ----------------------------------------------------------------------
  -- Bitvector operations.

  -- | Convert a signed bitvector to the nearest signed bitvector with
  -- the given width. If the resulting width is smaller, this clamps
  -- the value to min-int or max-int when necessary.
  intSetWidth :: (1 <= m, 1 <= n) => sym -> SymBV sym m -> NatRepr n -> IO (SymBV sym n)
  intSetWidth sym e n = do
    let m = bvWidth e
    case n `testNatCases` m of
      -- Truncate when the width of e is larger than w.
      NatCaseLT LeqProof -> do
        -- Check if e underflows
        does_underflow <- bvSlt sym e =<< bvLit sym m (BV.sext n m (BV.minSigned n))
        iteM bvIte sym does_underflow (bvLit sym n (BV.minSigned n)) $ do
          -- Check if e overflows target signed representation.
          does_overflow <- bvSgt sym e =<< bvLit sym m (BV.mkBV m (maxSigned n))
          iteM bvIte sym does_overflow (bvLit sym n (BV.maxSigned n)) $ do
            -- Just do truncation.
            bvTrunc sym n e
      NatCaseEQ -> return e
      NatCaseGT LeqProof -> bvSext sym n e

  -- | Convert an unsigned bitvector to the nearest unsigned bitvector with
  -- the given width (clamp on overflow).
  uintSetWidth :: (1 <= m, 1 <= n) => sym -> SymBV sym m -> NatRepr n -> IO (SymBV sym n)
  uintSetWidth sym e n = do
    let m = bvWidth e
    case n `testNatCases` m of
      NatCaseLT LeqProof -> do
        does_overflow <- bvUgt sym e =<< bvLit sym m (BV.mkBV m (maxUnsigned n))
        iteM bvIte sym does_overflow (bvLit sym n (BV.maxUnsigned n)) $ bvTrunc sym n e
      NatCaseEQ -> return e
      NatCaseGT LeqProof -> bvZext sym n e

  -- | Convert an signed bitvector to the nearest unsigned bitvector with
  -- the given width (clamp on overflow).
  intToUInt :: (1 <= m, 1 <= n) => sym -> SymBV sym m -> NatRepr n -> IO (SymBV sym n)
  intToUInt sym e w = do
    p <- bvIsNeg sym e
    iteM bvIte sym p (bvLit sym w (BV.zero w)) (uintSetWidth sym e w)

  -- | Convert an unsigned bitvector to the nearest signed bitvector with
  -- the given width (clamp on overflow).
  uintToInt :: (1 <= m, 1 <= n) => sym -> SymBV sym m -> NatRepr n -> IO (SymBV sym n)
  uintToInt sym e n = do
    let m = bvWidth e
    case n `testNatCases` m of
      NatCaseLT LeqProof -> do
        -- Get maximum signed n-bit number.
        max_val <- bvLit sym m (BV.sext n m (BV.maxSigned n))
        -- Check if expression is less than maximum.
        p <- bvUle sym e max_val
        -- Select appropriate number then truncate.
        bvTrunc sym n =<< bvIte sym p e max_val
      NatCaseEQ -> do
        max_val <- maxSignedBV sym n
        p <- bvUle sym e max_val
        bvIte sym p e max_val
      NatCaseGT LeqProof -> do
        bvZext sym n e

  ----------------------------------------------------------------------
  -- String operations

  -- | Create an empty string literal
  stringEmpty :: sym -> StringInfoRepr si -> IO (SymString sym si)

  -- | Create a concrete string literal
  stringLit :: sym -> StringLiteral si -> IO (SymString sym si)

  -- | Check the equality of two strings
  stringEq :: sym -> SymString sym si -> SymString sym si -> IO (Pred sym)

  -- | If-then-else on strings
  stringIte :: sym -> Pred sym -> SymString sym si -> SymString sym si -> IO (SymString sym si)

  -- | Concatenate two strings
  stringConcat :: sym -> SymString sym si -> SymString sym si -> IO (SymString sym si)

  -- | Test if the first string contains the second string as a substring
  stringContains ::
    sym ->
    SymString sym si {- ^ string to test -} ->
    SymString sym si {- ^ substring to look for -} ->
    IO (Pred sym)

  -- | Test if the first string is a prefix of the second string
  stringIsPrefixOf ::
    sym ->
    SymString sym si {- ^ prefix string -} ->
    SymString sym si {- ^ string to test -} ->
    IO (Pred sym)

  -- | Test if the first string is a suffix of the second string
  stringIsSuffixOf ::
    sym ->
    SymString sym si {- ^ suffix string -} ->
    SymString sym si {- ^ string to test -} ->
    IO (Pred sym)

  -- | Return the first position at which the second string can be found as a substring
  --   in the first string, starting from the given index.
  --   If no such position exists, return a negative value.
  --   If the given index is out of bounds for the string, return a negative value.
  stringIndexOf ::
    sym ->
    SymString sym si {- ^ string to search in -} ->
    SymString sym si {- ^ substring to search for -} ->
    SymInteger sym   {- ^ starting index for search -} ->
    IO (SymInteger sym)

  -- | Compute the length of a string
  stringLength :: sym -> SymString sym si -> IO (SymInteger sym)

  -- | @stringSubstring s off len@ evaluates to the longest substring
  --   of @s@ of length at most @len@ starting at position @off@.
  --   It evaluates to the empty string if @len@ is negative or @off@ is not in
  --   the interval @[0,l-1]@ where @l@ is the length of @s@.
  stringSubstring ::
    sym ->
    SymString sym si {- ^ string to select a substring from -} ->
    SymInteger sym   {- ^ offset of the beginning of the substring -} ->
    SymInteger sym   {- ^ length of the substring -} ->
    IO (SymString sym si)

  ----------------------------------------------------------------------
  -- Real operations

  -- | Return real number 0.
  realZero :: sym -> SymReal sym

  -- | Create a constant real literal.
  realLit :: sym -> Rational -> IO (SymReal sym)

  -- | Make a real literal from a scientific value. May be overridden
  -- if we want to avoid the overhead of converting scientific value
  -- to rational.
  sciLit :: sym -> Scientific -> IO (SymReal sym)
  sciLit sym s = realLit sym (toRational s)

  -- | Check equality of two real numbers.
  realEq :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)

  -- | Check non-equality of two real numbers.
  realNe :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)
  realNe sym x y = notPred sym =<< realEq sym x y

  -- | Check @<=@ on two real numbers.
  realLe :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)

  -- | Check @<@ on two real numbers.
  realLt :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)
  realLt sym x y = notPred sym =<< realLe sym y x

  -- | Check @>=@ on two real numbers.
  realGe :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)
  realGe sym x y = realLe sym y x

  -- | Check @>@ on two real numbers.
  realGt :: sym -> SymReal sym -> SymReal sym -> IO (Pred sym)
  realGt sym x y = realLt sym y x

  -- | If-then-else on real numbers.
  realIte :: sym -> Pred sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)

  -- | Return the minimum of two real numbers.
  realMin :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realMin sym x y =
    do p <- realLe sym x y
       realIte sym p x y

  -- | Return the maxmimum of two real numbers.
  realMax :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realMax sym x y =
    do p <- realLe sym x y
       realIte sym p y x

  -- | Negate a real number.
  realNeg :: sym -> SymReal sym -> IO (SymReal sym)

  -- | Add two real numbers.
  realAdd :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)

  -- | Multiply two real numbers.
  realMul :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)

  -- | Subtract one real from another.
  realSub :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realSub sym x y = realAdd sym x =<< realNeg sym y

  -- | @realSq sym x@ returns @x * x@.
  realSq :: sym -> SymReal sym -> IO (SymReal sym)
  realSq sym x = realMul sym x x

  -- | @realDiv sym x y@ returns term equivalent to @x/y@.
  --
  -- The result is undefined when @y@ is zero.
  realDiv :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)

  -- | @realMod x y@ returns the value of @x - y * floor(x / y)@ when
  -- @y@ is not zero and @x@ when @y@ is zero.
  realMod :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realMod sym x y = do
    isZero <- realEq sym y (realZero sym)
    iteM realIte sym isZero (return x) $ do
      realSub sym x =<< realMul sym y
                    =<< integerToReal sym
                    =<< realFloor sym
                    =<< realDiv sym x y

  -- | Predicate that holds if the real number is an exact integer.
  isInteger :: sym -> SymReal sym -> IO (Pred sym)

  -- | Return true if the real is non-negative.
  realIsNonNeg :: sym -> SymReal sym -> IO (Pred sym)
  realIsNonNeg sym x = realLe sym (realZero sym) x

  -- | @realSqrt sym x@ returns sqrt(x).  Result is undefined
  -- if @x@ is negative.
  realSqrt :: sym -> SymReal sym -> IO (SymReal sym)

  -- | Return value denoting pi.
  realPi :: sym -> IO (SymReal sym)
  realPi sym = realSpecialFunction0 sym Pi

  -- | Natural logarithm.  @realLog x@ is undefined
  --   for @x <= 0@.
  realLog :: sym -> SymReal sym -> IO (SymReal sym)
  realLog sym x = realSpecialFunction1 sym Log x

  -- | Natural exponentiation
  realExp :: sym -> SymReal sym -> IO (SymReal sym)
  realExp sym x = realSpecialFunction1 sym Exp x

  -- | Sine trig function
  realSin :: sym -> SymReal sym -> IO (SymReal sym)
  realSin sym x = realSpecialFunction1 sym Sin x

  -- | Cosine trig function
  realCos :: sym -> SymReal sym -> IO (SymReal sym)
  realCos sym x = realSpecialFunction1 sym Cos x

  -- | Tangent trig function.  @realTan x@ is undefined
  --   when @cos x = 0@,  i.e., when @x = pi/2 + k*pi@ for
  --   some integer @k@.
  realTan :: sym -> SymReal sym -> IO (SymReal sym)
  realTan sym x = realSpecialFunction1 sym Tan x

  -- | Hyperbolic sine
  realSinh :: sym -> SymReal sym -> IO (SymReal sym)
  realSinh sym x = realSpecialFunction1 sym Sinh x

  -- | Hyperbolic cosine
  realCosh :: sym -> SymReal sym -> IO (SymReal sym)
  realCosh sym x = realSpecialFunction1 sym Cosh x

  -- | Hyperbolic tangent
  realTanh :: sym -> SymReal sym -> IO (SymReal sym)
  realTanh sym x = realSpecialFunction1 sym Tanh x

  -- | Return absolute value of the real number.
  realAbs :: sym -> SymReal sym -> IO (SymReal sym)
  realAbs sym x = do
    c <- realGe sym x (realZero sym)
    realIte sym c x =<< realNeg sym x

  -- | @realHypot x y@ returns sqrt(x^2 + y^2).
  realHypot :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realHypot sym x y = do
    case (asRational x, asRational y) of
      (Just 0, _) -> realAbs sym y
      (_, Just 0) -> realAbs sym x
      _ -> do
        x2 <- realSq sym x
        y2 <- realSq sym y
        realSqrt sym =<< realAdd sym x2 y2

  -- | @realAtan2 sym y x@ returns the arctangent of @y/x@ with a range
  -- of @-pi@ to @pi@; this corresponds to the angle between the positive
  -- x-axis and the line from the origin @(x,y)@.
  --
  -- When @x@ is @0@ this returns @pi/2 * sgn y@.
  --
  -- When @x@ and @y@ are both zero, this function is undefined.
  realAtan2 :: sym -> SymReal sym -> SymReal sym -> IO (SymReal sym)
  realAtan2 sym y x = realSpecialFunction2 sym Arctan2 y x

  -- | Apply a special function to real arguments
  realSpecialFunction
    :: sym
    -> SpecialFunction args
    -> Ctx.Assignment (SpecialFnArg (SymExpr sym) BaseRealType) args
    -> IO (SymReal sym)

  -- | Access a 0-arity special function constant
  realSpecialFunction0
    :: sym
    -> SpecialFunction EmptyCtx
    -> IO (SymReal sym)
  realSpecialFunction0 sym fn =
    realSpecialFunction sym fn Ctx.Empty

  -- | Apply a 1-argument special function
  realSpecialFunction1
    :: sym
    -> SpecialFunction (EmptyCtx ::> R)
    -> SymReal sym
    -> IO (SymReal sym)
  realSpecialFunction1 sym fn x =
    realSpecialFunction sym fn (Ctx.Empty Ctx.:> SpecialFnArg x)

  -- | Apply a 2-argument special function
  realSpecialFunction2
    :: sym
    -> SpecialFunction (EmptyCtx ::> R ::> R)
    -> SymReal sym
    -> SymReal sym
    -> IO (SymReal sym)
  realSpecialFunction2 sym fn x y =
    realSpecialFunction sym fn (Ctx.Empty Ctx.:> SpecialFnArg x Ctx.:> SpecialFnArg y)

  ----------------------------------------------------------------------
  -- IEEE-754 floating-point operations
  -- | Return floating point number @+0@.
  floatPZero :: sym -> FloatPrecisionRepr fpp -> IO (SymFloat sym fpp)

  -- | Return floating point number @-0@.
  floatNZero :: sym -> FloatPrecisionRepr fpp -> IO (SymFloat sym fpp)

  -- |  Return floating point NaN.
  floatNaN :: sym -> FloatPrecisionRepr fpp -> IO (SymFloat sym fpp)

  -- | Return floating point @+infinity@.
  floatPInf :: sym -> FloatPrecisionRepr fpp -> IO (SymFloat sym fpp)

  -- | Return floating point @-infinity@.
  floatNInf :: sym -> FloatPrecisionRepr fpp -> IO (SymFloat sym fpp)

  -- | Create a floating point literal from a rational literal.
  --   The rational value will be rounded if necessary using the
  --   "round to nearest even" rounding mode.
  floatLitRational
    :: sym -> FloatPrecisionRepr fpp -> Rational -> IO (SymFloat sym fpp)
  floatLitRational sym fpp x = realToFloat sym fpp RNE =<< realLit sym x

  -- | Create a floating point literal from a @BigFloat@ value.
  floatLit :: sym -> FloatPrecisionRepr fpp -> BigFloat -> IO (SymFloat sym fpp)

  -- | Negate a floating point number.
  floatNeg
    :: sym
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Return the absolute value of a floating point number.
  floatAbs
    :: sym
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Compute the square root of a floating point number.
  floatSqrt
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Add two floating point numbers.
  floatAdd
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Subtract two floating point numbers.
  floatSub
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Multiply two floating point numbers.
  floatMul
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Divide two floating point numbers.
  floatDiv
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Compute the reminder: @x - y * n@, where @n@ in Z is nearest to @x / y@
  --   (breaking ties to even values of @n@).
  floatRem
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Return the minimum of two floating point numbers.
  --   If one argument is NaN, return the other argument.
  --   If the arguments are equal when compared as floating-point values,
  --   one of the two will be returned, but it is unspecified which;
  --   this underspecification can (only) be observed with zeros of different signs.
  floatMin
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Return the maximum of two floating point numbers.
  --   If one argument is NaN, return the other argument.
  --   If the arguments are equal when compared as floating-point values,
  --   one of the two will be returned, but it is unspecified which;
  --   this underspecification can (only) be observed with zeros of different signs.
  floatMax
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Compute the fused multiplication and addition: @(x * y) + z@.
  floatFMA
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Check logical equality of two floating point numbers.
  --
  --   NOTE! This does NOT accurately represent the equality test on floating point
  --   values typically found in programming languages.  See 'floatFpEq' instead.
  floatEq
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check logical non-equality of two floating point numbers.
  --
  --   NOTE! This does NOT accurately represent the non-equality test on floating point
  --   values typically found in programming languages.  See 'floatFpEq' instead.
  floatNe
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check IEEE-754 equality of two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not equal to itself!  Moreover, positive and negative 0 will
  --   compare equal, despite having different bit patterns.
  --
  --   This test is most appropriate for interpreting the equality tests of
  --   typical languages using floating point.  Moreover, not-equal tests
  --   are usually the negation of this test, rather than the `floatFpNe`
  --   test below.
  floatFpEq
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check IEEE-754 apartness of two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not apart from any other value!  Moreover, positive and
  --   negative 0 will not compare apart, despite having different
  --   bit patterns.  Note that @x@ is apart from @y@ iff @x < y@ or @x > y@.
  --
  --   This test usually does NOT correspond to the not-equal tests found
  --   in programming languages.  Instead, one generally takes the logical
  --   negation of the `floatFpEq` test.
  floatFpApart
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)
  floatFpApart sym x y =
    do l <- floatLt sym x y
       g <- floatGt sym x y
       orPred sym l g

  -- | Check if two floating point numbers are "unordered".  This happens
  --   precicely when one or both of the inputs is @NaN@.
  floatFpUnordered
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)
  floatFpUnordered sym x y =
    do xnan <- floatIsNaN sym x
       ynan <- floatIsNaN sym y
       orPred sym xnan ynan

  -- | Check IEEE-754 @<=@ on two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not less-than-or-equal-to any other value!  Moreover, positive
  --   and negative 0 are considered equal, despite having different bit patterns.
  floatLe
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check IEEE-754 @<@ on two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not less-than any other value! Moreover, positive
  --   and negative 0 are considered equal, despite having different bit patterns.
  floatLt
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check IEEE-754 @>=@ on two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not greater-than-or-equal-to any other value!  Moreover, positive
  --   and negative 0 are considered equal, despite having different bit patterns.
  floatGe
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Check IEEE-754 @>@ on two floating point numbers.
  --
  --   NOTE! This test returns false if either value is @NaN@; in particular
  --   @NaN@ is not greater-than any other value! Moreover, positive
  --   and negative 0 are considered equal, despite having different bit patterns.
  floatGt
    :: sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (Pred sym)

  -- | Test if a floating-point value is NaN.
  floatIsNaN :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is (positive or negative) infinity.
  floatIsInf :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is (positive or negative) zero.
  floatIsZero :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is positive.  NOTE!
  --   NaN is considered neither positive nor negative.
  floatIsPos :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is negative.  NOTE!
  --   NaN is considered neither positive nor negative.
  floatIsNeg :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is subnormal.
  floatIsSubnorm :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | Test if a floating-point value is normal.
  floatIsNorm :: sym -> SymFloat sym fpp -> IO (Pred sym)

  -- | If-then-else on floating point numbers.
  floatIte
    :: sym
    -> Pred sym
    -> SymFloat sym fpp
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)

  -- | Change the precision of a floating point number.
  floatCast
    :: sym
    -> FloatPrecisionRepr fpp
    -> RoundingMode
    -> SymFloat sym fpp'
    -> IO (SymFloat sym fpp)
  -- | Round a floating point number to an integral value.
  floatRound
    :: sym
    -> RoundingMode
    -> SymFloat sym fpp
    -> IO (SymFloat sym fpp)
  -- | Convert from binary representation in IEEE 754-2008 format to
  --   floating point.
  floatFromBinary
    :: (2 <= eb, 2 <= sb)
    => sym
    -> FloatPrecisionRepr (FloatingPointPrecision eb sb)
    -> SymBV sym (eb + sb)
    -> IO (SymFloat sym (FloatingPointPrecision eb sb))
  -- | Convert from floating point from to the binary representation in
  --   IEEE 754-2008 format.
  --
  --   NOTE! @NaN@ has multiple representations, i.e. all bit patterns where
  --   the exponent is @0b1..1@ and the significant is not @0b0..0@.
  --   This functions returns the representation of positive "quiet" @NaN@,
  --   i.e. the bit pattern where the sign is @0b0@, the exponent is @0b1..1@,
  --   and the significant is @0b10..0@.
  floatToBinary
    :: (2 <= eb, 2 <= sb)
    => sym
    -> SymFloat sym (FloatingPointPrecision eb sb)
    -> IO (SymBV sym (eb + sb))
  -- | Convert a unsigned bitvector to a floating point number.
  bvToFloat
    :: (1 <= w)
    => sym
    -> FloatPrecisionRepr fpp
    -> RoundingMode
    -> SymBV sym w
    -> IO (SymFloat sym fpp)
  -- | Convert a signed bitvector to a floating point number.
  sbvToFloat
    :: (1 <= w)
    => sym
    -> FloatPrecisionRepr fpp
    -> RoundingMode
    -> SymBV sym w
    -> IO (SymFloat sym fpp)
  -- | Convert a real number to a floating point number.
  realToFloat
    :: sym
    -> FloatPrecisionRepr fpp
    -> RoundingMode
    -> SymReal sym
    -> IO (SymFloat sym fpp)
  -- | Convert a floating point number to a unsigned bitvector.
  floatToBV
    :: (1 <= w)
    => sym
    -> NatRepr w
    -> RoundingMode
    -> SymFloat sym fpp
    -> IO (SymBV sym w)
  -- | Convert a floating point number to a signed bitvector.
  floatToSBV
    :: (1 <= w)
    => sym
    -> NatRepr w
    -> RoundingMode
    -> SymFloat sym fpp
    -> IO (SymBV sym w)
  -- | Convert a floating point number to a real number.
  floatToReal :: sym -> SymFloat sym fpp -> IO (SymReal sym)

  -- | Apply a special function to floating-point arguments
  floatSpecialFunction
    :: sym
    -> FloatPrecisionRepr fpp
    -> SpecialFunction args
    -> Ctx.Assignment (SpecialFnArg (SymExpr sym) (BaseFloatType fpp)) args
    -> IO (SymFloat sym fpp)

  ----------------------------------------------------------------------
  -- Cplx operations

  -- | Create a complex from cartesian coordinates.
  mkComplex :: sym -> Complex (SymReal sym) -> IO (SymCplx sym)

  -- | @getRealPart x@ returns the real part of @x@.
  getRealPart :: sym -> SymCplx sym -> IO (SymReal sym)

  -- | @getImagPart x@ returns the imaginary part of @x@.
  getImagPart :: sym -> SymCplx sym -> IO (SymReal sym)

  -- | Convert a complex number into the real and imaginary part.
  cplxGetParts :: sym -> SymCplx sym -> IO (Complex (SymReal sym))

  -- | Create a constant complex literal.
  mkComplexLit :: sym -> Complex Rational -> IO (SymCplx sym)
  mkComplexLit sym d = mkComplex sym =<< traverse (realLit sym) d

  -- | Create a complex from a real value.
  cplxFromReal :: sym -> SymReal sym -> IO (SymCplx sym)
  cplxFromReal sym r = mkComplex sym (r :+ realZero sym)

  -- | If-then-else on complex values.
  cplxIte :: sym -> Pred sym -> SymCplx sym -> SymCplx sym -> IO (SymCplx sym)
  cplxIte sym c x y = do
    case asConstantPred c of
      Just True -> return x
      Just False -> return y
      _ -> do
        xr :+ xi <- cplxGetParts sym x
        yr :+ yi <- cplxGetParts sym y
        zr <- realIte sym c xr yr
        zi <- realIte sym c xi yi
        mkComplex sym (zr :+ zi)

  -- | Negate a complex number.
  cplxNeg :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxNeg sym x = mkComplex sym =<< traverse (realNeg sym) =<< cplxGetParts sym x

  -- | Add two complex numbers together.
  cplxAdd :: sym -> SymCplx sym -> SymCplx sym -> IO (SymCplx sym)
  cplxAdd sym x y = do
    xr :+ xi <- cplxGetParts sym x
    yr :+ yi <- cplxGetParts sym y
    zr <- realAdd sym xr yr
    zi <- realAdd sym xi yi
    mkComplex sym (zr :+ zi)

  -- | Subtract one complex number from another.
  cplxSub :: sym -> SymCplx sym -> SymCplx sym -> IO (SymCplx sym)
  cplxSub sym x y = do
    xr :+ xi <- cplxGetParts sym x
    yr :+ yi <- cplxGetParts sym y
    zr <- realSub sym xr yr
    zi <- realSub sym xi yi
    mkComplex sym (zr :+ zi)

  -- | Multiply two complex numbers together.
  cplxMul :: sym -> SymCplx sym -> SymCplx sym -> IO (SymCplx sym)
  cplxMul sym x y = do
    xr :+ xi <- cplxGetParts sym x
    yr :+ yi <- cplxGetParts sym y
    rz0 <- realMul sym xr yr
    rz <- realSub sym rz0 =<< realMul sym xi yi
    iz0 <- realMul sym xi yr
    iz <- realAdd sym iz0 =<< realMul sym xr yi
    mkComplex sym (rz :+ iz)

  -- | Compute the magnitude of a complex number.
  cplxMag :: sym -> SymCplx sym -> IO (SymReal sym)
  cplxMag sym x = do
    (xr :+ xi) <- cplxGetParts sym x
    realHypot sym xr xi

  -- | Return the principal square root of a complex number.
  cplxSqrt :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxSqrt sym x = do
    (r_part :+ i_part) <- cplxGetParts sym x
    case (asRational r_part :+ asRational i_part)of
      (Just r :+ Just i) | Just z <- tryComplexSqrt tryRationalSqrt (r :+ i) ->
        mkComplexLit sym z

      (_ :+ Just 0) -> do
        c <- realGe sym r_part (realZero sym)
        u <- iteM realIte sym c
          (realSqrt sym r_part)
          (realLit sym 0)
        v <- iteM realIte sym c
          (realLit sym 0)
          (realSqrt sym =<< realNeg sym r_part)
        mkComplex sym (u :+ v)

      _ -> do
        m <- realHypot sym r_part i_part
        m_plus_r <- realAdd sym m r_part
        m_sub_r  <- realSub sym m r_part
        two <- realLit sym 2
        u <- realSqrt sym =<< realDiv sym m_plus_r two
        v <- realSqrt sym =<< realDiv sym m_sub_r  two
        neg_v <- realNeg sym v
        i_part_nonneg <- realIsNonNeg sym i_part
        v' <- realIte sym i_part_nonneg v neg_v
        mkComplex sym (u :+ v')

  -- | Compute sine of a complex number.
  cplxSin :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxSin sym arg = do
    c@(x :+ y) <- cplxGetParts sym arg
    case asRational <$> c of
      (Just 0 :+ Just 0) -> cplxFromReal sym (realZero sym)
      (_ :+ Just 0) -> cplxFromReal sym =<< realSin sym x
      (Just 0 :+ _) -> do
        -- sin(0 + bi) = sin(0) cosh(b) + i*cos(0)sinh(b) = i*sinh(b)
        sinh_y <- realSinh sym y
        mkComplex sym (realZero sym :+ sinh_y)
      _ -> do
        sin_x <- realSin sym x
        cos_x <- realCos sym x
        sinh_y <- realSinh sym y
        cosh_y <- realCosh sym y
        r_part <- realMul sym sin_x cosh_y
        i_part <- realMul sym cos_x sinh_y
        mkComplex sym (r_part :+ i_part)

  -- | Compute cosine of a complex number.
  cplxCos :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxCos sym arg = do
    c@(x :+ y) <- cplxGetParts sym arg
    case asRational <$> c of
      (Just 0 :+ Just 0) -> cplxFromReal sym =<< realLit sym 1
      (_ :+ Just 0) -> cplxFromReal sym =<< realCos sym x
      (Just 0 :+ _) -> do
        -- cos(0 + bi) = cos(0) cosh(b) - i*sin(0)sinh(b) = cosh(b)
        cosh_y    <- realCosh sym y
        cplxFromReal sym cosh_y
      _ -> do
        neg_sin_x <- realNeg sym =<< realSin sym x
        cos_x     <- realCos sym x
        sinh_y    <- realSinh sym y
        cosh_y    <- realCosh sym y
        r_part <- realMul sym cos_x cosh_y
        i_part <- realMul sym neg_sin_x sinh_y
        mkComplex sym (r_part :+ i_part)

  -- | Compute tangent of a complex number.  @cplxTan x@ is undefined
  --   when @cplxCos x@ is @0@, which occurs only along the real line
  --   in the same conditions where @realCos x@ is @0@.
  cplxTan :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxTan sym arg = do
    c@(x :+ y) <- cplxGetParts sym arg
    case asRational <$> c of
      (Just 0 :+ Just 0) -> cplxFromReal sym (realZero sym)
      (_ :+ Just 0) -> do
        cplxFromReal sym =<< realTan sym x
      (Just 0 :+ _) -> do
        i_part <- realTanh sym y
        mkComplex sym (realZero sym :+ i_part)
      _ -> do
        sin_x <- realSin sym x
        cos_x <- realCos sym x
        sinh_y <- realSinh sym y
        cosh_y <- realCosh sym y
        u <- realMul sym cos_x cosh_y
        v <- realMul sym sin_x sinh_y
        u2 <- realMul sym u u
        v2 <- realMul sym v v
        m <- realAdd sym u2 v2
        sin_x_cos_x   <- realMul sym sin_x cos_x
        sinh_y_cosh_y <- realMul sym sinh_y cosh_y
        r_part <- realDiv sym sin_x_cos_x m
        i_part <- realDiv sym sinh_y_cosh_y m
        mkComplex sym (r_part :+ i_part)

  -- | @hypotCplx x y@ returns @sqrt(abs(x)^2 + abs(y)^2)@.
  cplxHypot :: sym -> SymCplx sym -> SymCplx sym -> IO (SymCplx sym)
  cplxHypot sym x y = do
    (xr :+ xi) <- cplxGetParts sym x
    (yr :+ yi) <- cplxGetParts sym y
    xr2 <- realSq sym xr
    xi2 <- realSq sym xi
    yr2 <- realSq sym yr
    yi2 <- realSq sym yi

    r2 <- foldM (realAdd sym) xr2 [xi2, yr2, yi2]
    cplxFromReal sym =<< realSqrt sym r2

  -- | @roundCplx x@ rounds complex number to nearest integer.
  -- Numbers with a fractional part of 0.5 are rounded away from 0.
  -- Imaginary and real parts are rounded independently.
  cplxRound :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxRound sym x = do
    c <- cplxGetParts sym x
    mkComplex sym =<< traverse (integerToReal sym <=< realRound sym) c

  -- | @cplxFloor x@ rounds to nearest integer less than or equal to x.
  -- Imaginary and real parts are rounded independently.
  cplxFloor :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxFloor sym x =
    mkComplex sym =<< traverse (integerToReal sym <=< realFloor sym)
                  =<< cplxGetParts sym x
  -- | @cplxCeil x@ rounds to nearest integer greater than or equal to x.
  -- Imaginary and real parts are rounded independently.
  cplxCeil :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxCeil sym x =
    mkComplex sym =<< traverse (integerToReal sym <=< realCeil sym)
                  =<< cplxGetParts sym x

  -- | @conjReal x@ returns the complex conjugate of the input.
  cplxConj :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxConj sym x  = do
    r :+ i <- cplxGetParts sym x
    ic <- realNeg sym i
    mkComplex sym (r :+ ic)

  -- | Returns exponential of a complex number.
  cplxExp :: sym -> SymCplx sym -> IO (SymCplx sym)
  cplxExp sym x = do
    (rx :+ i_part) <- cplxGetParts sym x
    expx <- realExp sym rx
    cosx <- realCos sym i_part
    sinx <- realSin sym i_part
    rz <- realMul sym expx cosx
    iz <- realMul sym expx sinx
    mkComplex sym (rz :+ iz)

  -- | Check equality of two complex numbers.
  cplxEq :: sym -> SymCplx sym -> SymCplx sym -> IO (Pred sym)
  cplxEq sym x y = do
    xr :+ xi <- cplxGetParts sym x
    yr :+ yi <- cplxGetParts sym y
    pr <- realEq sym xr yr
    pj <- realEq sym xi yi
    andPred sym pr pj

  -- | Check non-equality of two complex numbers.
  cplxNe :: sym -> SymCplx sym -> SymCplx sym -> IO (Pred sym)
  cplxNe sym x y = do
    xr :+ xi <- cplxGetParts sym x
    yr :+ yi <- cplxGetParts sym y
    pr <- realNe sym xr yr
    pj <- realNe sym xi yi
    orPred sym pr pj

-- | This newtype is necessary for @bvJoinVector@ and @bvSplitVector@.
-- These both use functions from Data.Parameterized.Vector that
-- that expect a wrapper of kind (Type -> Type), and we can't partially
-- apply the type synonym (e.g. SymBv sym), whereas we can partially
-- apply this newtype.
newtype SymBV' sym w = MkSymBV' (SymBV sym w)

-- | Join a @Vector@ of smaller bitvectors.  The vector is
--   interpreted in big endian order; that is, with most
--   significant bitvector first.
bvJoinVector :: forall sym n w. (1 <= w, IsExprBuilder sym)
             => sym
             -> NatRepr w
             -> Vector.Vector n (SymBV sym w)
             -> IO (SymBV sym (n * w))
bvJoinVector sym w =
  coerce $ Vector.joinWithM @IO @(SymBV' sym) @n bvConcat' w
  where bvConcat' :: forall l. (1 <= l)
                  => NatRepr l
                  -> SymBV' sym w
                  -> SymBV' sym l
                  -> IO (SymBV' sym (w + l))
        bvConcat' _ (MkSymBV' x) (MkSymBV' y) = MkSymBV' <$> bvConcat sym x y

-- | Split a bitvector to a @Vector@ of smaller bitvectors.
--   The returned vector is in big endian order; that is, with most
--   significant bitvector first.
bvSplitVector :: forall sym n w. (IsExprBuilder sym, 1 <= w, 1 <= n)
              => sym
              -> NatRepr n
              -> NatRepr w
              -> SymBV sym (n * w)
              -> IO (Vector.Vector n (SymBV sym w))
bvSplitVector sym n w x =
  coerce $ Vector.splitWithA @IO BigEndian bvSelect' n w (MkSymBV' @sym x)
  where
    bvSelect' :: forall i. (i + w <= n * w)
              => NatRepr (n * w)
              -> NatRepr i
              -> SymBV' sym (n * w)
              -> IO (SymBV' sym w)
    bvSelect' _ i (MkSymBV' y) =
      fmap MkSymBV' $ bvSelect @_ @i @w sym i w y

-- | Implement LLVM's "bswap" intrinsic
--
-- See <https://llvm.org/docs/LangRef.html#llvm-bswap-intrinsics
--       the LLVM @bswap@ documentation.>
--
-- This is the implementation in SawCore:
--
-- > llvmBSwap :: (n :: Nat) -> bitvector (mulNat n 8) -> bitvector (mulNat n 8);
-- > llvmBSwap n x = join n 8 Bool (reverse n (bitvector 8) (split n 8 Bool x));
bvSwap :: forall sym n. (1 <= n, IsExprBuilder sym)
       => sym               -- ^ Symbolic interface
       -> NatRepr n
       -> SymBV sym (n*8)   -- ^ Bitvector to swap around
       -> IO (SymBV sym (n*8))
bvSwap sym n v = do
  bvJoinVector sym (knownNat @8) . Vector.reverse
    =<< bvSplitVector sym n (knownNat @8) v

-- | Swap the order of the bits in a bitvector.
bvBitreverse :: forall sym w.
  (1 <= w, IsExprBuilder sym) =>
  sym ->
  SymBV sym w ->
  IO (SymBV sym w)
bvBitreverse sym v = do
  bvJoinVector sym (knownNat @1) . Vector.reverse
    =<< bvSplitVector sym (bvWidth v) (knownNat @1) v


-- | Create a literal from an 'IndexLit'.
indexLit :: IsExprBuilder sym => sym -> IndexLit idx -> IO (SymExpr sym idx)
indexLit sym (IntIndexLit i)  = intLit sym i
indexLit sym (BVIndexLit w v) = bvLit sym w v

-- | A utility combinator for combining actions
--   that build terms with if/then/else.
--   If the given predicate is concretely true or
--   false only the corresponding "then" or "else"
--   action is run; otherwise both actions are run
--   and combined with the given "ite" action.
iteM :: IsExprBuilder sym =>
  (sym -> Pred sym -> v -> v -> IO v) ->
  sym -> Pred sym -> IO v -> IO v -> IO v
iteM ite sym p mx my = do
  case asConstantPred p of
    Just True -> mx
    Just False -> my
    Nothing -> join $ ite sym p <$> mx <*> my

-- | An iterated sequence of if/then/else operations.
--   The list of predicates and "then" results is
--   constructed as-needed. The "default" value
--   represents the result of the expression if
--   none of the predicates in the given list
--   is true.
iteList :: IsExprBuilder sym =>
  (sym -> Pred sym -> v -> v -> IO v) ->
  sym ->
  [(IO (Pred sym), IO v)] ->
  (IO v) ->
  IO v
iteList _ite _sym [] def = def
iteList ite sym ((mp,mx):xs) def =
  do p <- mp
     iteM ite sym p mx (iteList ite sym xs def)

-- | A function that can be applied to symbolic arguments.
--
-- This type is used by some methods in classes 'IsExprBuilder' and
-- 'IsSymExprBuilder'.
type family SymFn sym :: Ctx BaseType -> BaseType -> Type

-- | A class for extracting type representatives from symbolic functions
class IsSymFn fn where
  -- | Get the argument types of a function.
  fnArgTypes :: fn args ret -> Ctx.Assignment BaseTypeRepr args

  -- | Get the return type of a function.
  fnReturnType :: fn args ret -> BaseTypeRepr ret


-- | Describes when we unfold the body of defined functions.
data UnfoldPolicy
  = NeverUnfold
      -- ^ What4 will not unfold the body of functions when applied to arguments
   | AlwaysUnfold
      -- ^ The function will be unfolded into its definition whenever it is
      --   applied to arguments
   | UnfoldConcrete
      -- ^ The function will be unfolded into its definition only if all the provided
      --   arguments are concrete.
 deriving (Eq, Ord, Show)

-- | Evaluates an @UnfoldPolicy@ on a collection of arguments.
shouldUnfold :: IsExpr e => UnfoldPolicy -> Ctx.Assignment e args -> Bool
shouldUnfold AlwaysUnfold _ = True
shouldUnfold NeverUnfold _ = False
shouldUnfold UnfoldConcrete args = allFC baseIsConcrete args


-- | This exception is thrown if the user requests to make a bounded variable,
--   but gives incoherent or out-of-range bounds.
data InvalidRange where
  InvalidRange ::
    BaseTypeRepr bt ->
    Maybe (ConcreteValue bt) ->
    Maybe (ConcreteValue bt) ->
    InvalidRange

instance Exception InvalidRange
instance Show InvalidRange where
  show (InvalidRange bt mlo mhi) =
    case bt of
      BaseIntegerRepr -> unwords ["invalid integer range", show mlo, show mhi]
      BaseRealRepr    -> unwords ["invalid real range", show mlo, show mhi]
      BaseBVRepr w    -> unwords ["invalid bitvector range", show w ++ "-bit", show mlo, show mhi]
      _               -> unwords ["invalid range for type", show bt]

-- | This extends the interface for building expressions with operations
--   for creating new symbolic constants and functions.
class ( IsExprBuilder sym
      , IsSymFn (SymFn sym)
      , OrdF (SymExpr sym)
      ) => IsSymExprBuilder sym where

  ----------------------------------------------------------------------
  -- Fresh variables

  -- | Create a fresh top-level uninterpreted constant.
  freshConstant :: sym -> SolverSymbol -> BaseTypeRepr tp -> IO (SymExpr sym tp)

  -- | Create a fresh latch variable.
  freshLatch    :: sym -> SolverSymbol -> BaseTypeRepr tp -> IO (SymExpr sym tp)

  -- | Create a fresh bitvector value with optional lower and upper bounds (which bound the
  --   unsigned value of the bitvector). If provided, the bounds are inclusive.
  --   If inconsistent or out-of-range bounds are given, an @InvalidRange@ exception will be thrown.
  freshBoundedBV :: (1 <= w) =>
    sym ->
    SolverSymbol ->
    NatRepr w ->
    Maybe Natural {- ^ lower bound -} ->
    Maybe Natural {- ^ upper bound -} ->
    IO (SymBV sym w)

  -- | Create a fresh bitvector value with optional lower and upper bounds (which bound the
  --   signed value of the bitvector).  If provided, the bounds are inclusive.
  --   If inconsistent or out-of-range bounds are given, an InvalidRange exception will be thrown.
  freshBoundedSBV :: (1 <= w) =>
    sym ->
    SolverSymbol ->
    NatRepr w ->
    Maybe Integer {- ^ lower bound -} ->
    Maybe Integer {- ^ upper bound -} ->
    IO (SymBV sym w)

  -- | Create a fresh integer constant with optional lower and upper bounds.
  --   If provided, the bounds are inclusive.
  --   If inconsistent bounds are given, an InvalidRange exception will be thrown.
  freshBoundedInt ::
    sym ->
    SolverSymbol ->
    Maybe Integer {- ^ lower bound -} ->
    Maybe Integer {- ^ upper bound -} ->
    IO (SymInteger sym)

  -- | Create a fresh real constant with optional lower and upper bounds.
  --   If provided, the bounds are inclusive.
  --   If inconsistent bounds are given, an InvalidRange exception will be thrown.
  freshBoundedReal ::
    sym ->
    SolverSymbol ->
    Maybe Rational {- ^ lower bound -} ->
    Maybe Rational {- ^ upper bound -} ->
    IO (SymReal sym)

  -- | Return the set of uninterpreted constants in the given expression.
  exprUninterpConstants :: sym -> SymExpr sym tp -> Set (Some (BoundVar sym))


  ----------------------------------------------------------------------
  -- Functions needs to support quantifiers.

  -- | Creates a bound variable.
  --
  -- This will be treated as a free constant when appearing inside asserted
  -- expressions.  These are intended to be bound using quantifiers or
  -- symbolic functions.
  freshBoundVar :: sym -> SolverSymbol -> BaseTypeRepr tp -> IO (BoundVar sym tp)

  -- | Return an expression that references the bound variable.
  varExpr :: sym -> BoundVar sym tp -> SymExpr sym tp

  -- | @forallPred sym v e@ returns an expression that represents @forall v . e@.
  -- Throws a user error if bound var has already been used in a quantifier.
  forallPred :: sym
             -> BoundVar sym tp
             -> Pred sym
             -> IO (Pred sym)

  -- | @existsPred sym v e@ returns an expression that represents @exists v . e@.
  -- Throws a user error if bound var has already been used in a quantifier.
  existsPred :: sym
             -> BoundVar sym tp
             -> Pred sym
             -> IO (Pred sym)

  ----------------------------------------------------------------------
  -- SymFn operations.

  -- | Return a function defined by an expression over bound
  -- variables. The predicate argument allows the user to specify when
  -- an application of the function should be unfolded and evaluated,
  -- e.g. to perform constant folding.
  definedFn :: sym
            -- ^ Symbolic interface
            -> SolverSymbol
            -- ^ The name to give a function (need not be unique)
            -> Ctx.Assignment (BoundVar sym) args
            -- ^ Bound variables to use as arguments for function.
            -> SymExpr sym ret
            -- ^ Operation defining result of defined function.
            -> UnfoldPolicy
            -- ^ Policy for unfolding on applications
            -> IO (SymFn sym args ret)

  -- | Return a function defined by Haskell computation over symbolic expressions.
  inlineDefineFun :: Ctx.CurryAssignmentClass args
                  => sym
                     -- ^ Symbolic interface
                  -> SolverSymbol
                  -- ^ The name to give a function (need not be unique)
                  -> Ctx.Assignment BaseTypeRepr args
                  -- ^ Type signature for the arguments
                  -> UnfoldPolicy
                  -- ^ Policy for unfolding on applications
                  -> Ctx.CurryAssignment args (SymExpr sym) (IO (SymExpr sym ret))
                  -- ^ Operation defining result of defined function.
                  -> IO (SymFn sym args ret)
  inlineDefineFun sym nm tps policy f = do
    -- Create bound variables for function
    vars <- traverseFC (freshBoundVar sym emptySymbol) tps
    -- Call operation on expressions created from variables
    r <- Ctx.uncurryAssignment f (fmapFC (varExpr sym) vars)
    -- Define function
    definedFn sym nm vars r policy

  -- | Create a new uninterpreted function.
  freshTotalUninterpFn :: forall args ret
                        .  sym
                          -- ^ Symbolic interface
                       -> SolverSymbol
                          -- ^ The name to give a function (need not be unique)
                       -> Ctx.Assignment BaseTypeRepr args
                          -- ^ Types of arguments expected by function
                       -> BaseTypeRepr ret
                           -- ^ Return type of function
                       -> IO (SymFn sym args ret)

  -- | Apply a set of arguments to a symbolic function.
  applySymFn :: sym
                -- ^ Symbolic interface
             -> SymFn sym args ret
                -- ^ Function to call
             -> Ctx.Assignment (SymExpr sym) args
                -- ^ Arguments to function
             -> IO (SymExpr sym ret)

-- | This returns true if the value corresponds to a concrete value.
baseIsConcrete :: forall e bt
                . IsExpr e
               => e bt
               -> Bool
baseIsConcrete x =
  case exprType x of
    BaseBoolRepr    -> isJust $ asConstantPred x
    BaseIntegerRepr -> isJust $ asInteger x
    BaseBVRepr _    -> isJust $ asBV x
    BaseRealRepr    -> isJust $ asRational x
    BaseFloatRepr _ -> False
    BaseStringRepr{} -> isJust $ asString x
    BaseComplexRepr -> isJust $ asComplex x
    BaseStructRepr _ -> case asStruct x of
        Just flds -> allFC baseIsConcrete flds
        Nothing -> False
    BaseArrayRepr _ _bt' -> do
      case asConstantArray x of
        Just x' -> baseIsConcrete x'
        Nothing -> False

-- | Return some default value for each base type.
--   For numeric types, this is 0; for booleans, false;
--   for strings, the empty string.  Structs are
--   filled with default values for every field,
--   default arrays are constant arrays of default values.
baseDefaultValue :: forall sym bt
                  . IsExprBuilder sym
                 => sym
                 -> BaseTypeRepr bt
                 -> IO (SymExpr sym bt)
baseDefaultValue sym bt =
  case bt of
    BaseBoolRepr    -> return $! falsePred sym
    BaseIntegerRepr -> intLit sym 0
    BaseBVRepr w    -> bvLit sym w (BV.zero w)
    BaseRealRepr    -> return $! realZero sym
    BaseFloatRepr fpp -> floatPZero sym fpp
    BaseComplexRepr -> mkComplexLit sym (0 :+ 0)
    BaseStringRepr si -> stringEmpty sym si
    BaseStructRepr flds -> do
      let f :: BaseTypeRepr tp -> IO (SymExpr sym tp)
          f v = baseDefaultValue sym v
      mkStruct sym =<< traverseFC f flds
    BaseArrayRepr idx bt' -> do
      elt <- baseDefaultValue sym bt'
      constantArray sym idx elt

-- | Return predicate equivalent to a Boolean.
backendPred :: IsExprBuilder sym => sym -> Bool -> Pred sym
backendPred sym True  = truePred  sym
backendPred sym False = falsePred sym

-- | Create a value from a rational.
mkRational :: IsExprBuilder sym => sym -> Rational -> IO (SymCplx sym)
mkRational sym v = mkComplexLit sym (v :+ 0)

-- | Create a value from an integer.
mkReal  :: (IsExprBuilder sym, Real a) => sym -> a -> IO (SymCplx sym)
mkReal sym v = mkRational sym (toRational v)

-- | Return 1 if the predicate is true; 0 otherwise.
predToReal :: IsExprBuilder sym => sym -> Pred sym -> IO (SymReal sym)
predToReal sym p = do
  r1 <- realLit sym 1
  realIte sym p r1 (realZero sym)

-- | Extract the value of a rational expression; fail if the
--   value is not a constant.
realExprAsRational :: (MonadFail m, IsExpr e) => e BaseRealType -> m Rational
realExprAsRational x = do
  case asRational x of
    Just r -> return r
    Nothing -> fail "Value is not a constant expression."

-- | Extract the value of a complex expression, which is assumed
--   to be a constant real number.  Fail if the number has nonzero
--   imaginary component, or if it is not a constant.
cplxExprAsRational :: (MonadFail m, IsExpr e) => e BaseComplexType -> m Rational
cplxExprAsRational x = do
  case asComplex x of
    Just (r :+ i) -> do
      when (i /= 0) $
        fail "Complex value has an imaginary part."
      return r
    Nothing -> do
      fail "Complex value is not a constant expression."

-- | Return a complex value as a constant integer if it exists.
cplxExprAsInteger :: (MonadFail m, IsExpr e) => e BaseComplexType -> m Integer
cplxExprAsInteger x = rationalAsInteger =<< cplxExprAsRational x

-- | Return value as a constant integer if it exists.
rationalAsInteger :: MonadFail m => Rational -> m Integer
rationalAsInteger r = do
  when (denominator r /= 1) $ do
    fail "Value is not an integer."
  return (numerator r)

-- | Return value as a constant integer if it exists.
realExprAsInteger :: (IsExpr e, MonadFail m) => e BaseRealType -> m Integer
realExprAsInteger x =
  rationalAsInteger =<< realExprAsRational x

-- | Compute the conjunction of a sequence of predicates.
andAllOf :: IsExprBuilder sym
         => sym
         -> Fold s (Pred sym)
         -> s
         -> IO (Pred sym)
andAllOf sym f s = foldlMOf f (andPred sym) (truePred sym) s

-- | Compute the disjunction of a sequence of predicates.
orOneOf :: IsExprBuilder sym
         => sym
         -> Fold s (Pred sym)
         -> s
         -> IO (Pred sym)
orOneOf sym f s = foldlMOf f (orPred sym) (falsePred sym) s

-- | Return predicate that holds if value is non-zero.
isNonZero :: IsExprBuilder sym => sym -> SymCplx sym -> IO (Pred sym)
isNonZero sym v = cplxNe sym v =<< mkRational sym 0

-- | Return predicate that holds if imaginary part of number is zero.
isReal :: IsExprBuilder sym => sym -> SymCplx sym -> IO (Pred sym)
isReal sym v = do
  i <- getImagPart sym v
  realEq sym i (realZero sym)

-- | Divide one number by another.
--
--   @cplxDiv x y@ is undefined when @y@ is @0@.
cplxDiv :: IsExprBuilder sym
        => sym
        -> SymCplx sym
        -> SymCplx sym
        -> IO (SymCplx sym)
cplxDiv sym x y = do
  xr :+ xi <- cplxGetParts sym x
  yc@(yr :+ yi) <- cplxGetParts sym y
  case asRational <$> yc of
    (_ :+ Just 0) -> do
      zc <- (:+) <$> realDiv sym xr yr <*> realDiv sym xi yr
      mkComplex sym zc
    (Just 0 :+ _) -> do
      zc <- (:+) <$> realDiv sym xi yi <*> realDiv sym xr yi
      mkComplex sym zc
    _ -> do
      yr_abs <- realMul sym yr yr
      yi_abs <- realMul sym yi yi
      y_abs <- realAdd sym yr_abs yi_abs

      zr_1 <- realMul sym xr yr
      zr_2 <- realMul sym xi yi
      zr <- realAdd sym zr_1 zr_2

      zi_1 <- realMul sym xi yr
      zi_2 <- realMul sym xr yi
      zi <- realSub sym zi_1 zi_2

      zc <- (:+) <$> realDiv sym zr y_abs <*> realDiv sym zi y_abs
      mkComplex sym zc

-- | Helper function that returns the principal logarithm of input.
cplxLog' :: IsExprBuilder sym
         => sym -> SymCplx sym -> IO (Complex (SymReal sym))
cplxLog' sym x = do
  xr :+ xi <- cplxGetParts sym x
  -- Get the magnitude of the value.
  xm <- realHypot sym xr xi
  -- Get angle of complex number.
  xa <- realAtan2 sym xi xr
  -- Get log of magnitude
  zr <- realLog sym xm
  return $! zr :+ xa

-- | Returns the principal logarithm of the input value.
--
--   @cplxLog x@ is undefined when @x@ is @0@, and has a
--   cut discontinuity along the negative real line.
cplxLog :: IsExprBuilder sym
        => sym -> SymCplx sym -> IO (SymCplx sym)
cplxLog sym x = mkComplex sym =<< cplxLog' sym x

-- | Returns logarithm of input at a given base.
--
--   @cplxLogBase b x@ is undefined when @x@ is @0@.
cplxLogBase :: IsExprBuilder sym
            => Rational {- ^ Base for the logarithm -}
            -> sym
            -> SymCplx sym
            -> IO (SymCplx sym)
cplxLogBase base sym x = do
  b <- realLog sym =<< realLit sym base
  z <- traverse (\r -> realDiv sym r b) =<< cplxLog' sym x
  mkComplex sym z

--------------------------------------------------------------------------
-- Relationship to concrete values

-- | Return a concrete representation of a value, if it
--   is concrete.
asConcrete :: IsExpr e => e tp -> Maybe (ConcreteVal tp)
asConcrete x =
  case exprType x of
    BaseBoolRepr       -> ConcreteBool <$> asConstantPred x
    BaseIntegerRepr    -> ConcreteInteger <$> asInteger x
    BaseRealRepr       -> ConcreteReal <$> asRational x
    BaseStringRepr _si -> ConcreteString <$> asString x
    BaseComplexRepr    -> ConcreteComplex <$> asComplex x
    BaseBVRepr w       -> ConcreteBV w <$> asBV x
    BaseFloatRepr fpp  -> ConcreteFloat fpp <$> asFloat x
    BaseStructRepr _   -> ConcreteStruct <$> (asStruct x >>= traverseFC asConcrete)
    BaseArrayRepr idx _tp -> do
      def <- asConstantArray x
      c_def <- asConcrete def
      -- TODO: what about cases where there are updates to the array?
      -- Passing Map.empty is probably wrong.
      pure (ConcreteArray idx c_def Map.empty)

-- | Create a literal symbolic value from a concrete value.
concreteToSym :: IsExprBuilder sym => sym -> ConcreteVal tp -> IO (SymExpr sym tp)
concreteToSym sym = \case
   ConcreteBool True    -> return (truePred sym)
   ConcreteBool False   -> return (falsePred sym)
   ConcreteInteger x    -> intLit sym x
   ConcreteReal x       -> realLit sym x
   ConcreteFloat fpp bf -> floatLit sym fpp bf
   ConcreteString x     -> stringLit sym x
   ConcreteComplex x    -> mkComplexLit sym x
   ConcreteBV w x       -> bvLit sym w x
   ConcreteStruct xs    -> mkStruct sym =<< traverseFC (concreteToSym sym) xs
   ConcreteArray idxTy def xs0 -> go (Map.toAscList xs0) =<< constantArray sym idxTy =<< concreteToSym sym def
     where
     go [] arr = return arr
     go ((i,x):xs) arr =
        do arr' <- go xs arr
           i' <- traverseFC (concreteToSym sym) i
           x' <- concreteToSym sym x
           arrayUpdate sym arr' i' x'

------------------------------------------------------------------------
-- muxNatRange

{-# INLINABLE muxRange #-}
{- | This function is used for selecting a value from among potential
values in a range.

@muxRange p ite f l h@ returns an expression denoting the value obtained
from the value @f i@ where @i@ is the smallest value in the range @[l..h]@
such that @p i@ is true.  If @p i@ is true for no such value, then
this returns the value @f h@. -}
muxRange :: (IsExpr e, Monad m) =>
   (Natural -> m (e BaseBoolType))
      {- ^ Returns predicate that holds if we have found the value we are looking
           for.  It is assumed that the predicate must hold for a unique integer in
           the range.
      -} ->
   (e BaseBoolType -> a -> a -> m a) {- ^ Ite function -} ->
   (Natural -> m a) {- ^ Function for concrete values -} ->
   Natural {- ^ Lower bound (inclusive) -} ->
   Natural {- ^ Upper bound (inclusive) -} ->
   m a
muxRange predFn iteFn f l h
  | l < h = do
    c <- predFn l
    case asConstantPred c of
      Just True  -> f l
      Just False -> muxRange predFn iteFn f (succ l) h
      Nothing ->
        do match_branch <- f l
           other_branch <- muxRange predFn iteFn f (succ l) h
           iteFn c match_branch other_branch
  | otherwise = f h

-- | This provides an interface for converting between Haskell values and a
-- solver representation.
data SymEncoder sym v tp
   = SymEncoder { symEncoderType :: !(BaseTypeRepr tp)
                , symFromExpr :: !(sym -> SymExpr sym tp -> IO v)
                , symToExpr   :: !(sym -> v -> IO (SymExpr sym tp))
                }

----------------------------------------------------------------------
-- Statistics

-- | Statistics gathered on a running expression builder.  See
-- 'getStatistics'.
data Statistics
  = Statistics { statAllocs :: !Integer
                 -- ^ The number of times an expression node has been
                 -- allocated.
               , statNonLinearOps :: !Integer
                 -- ^ The number of non-linear operations, such as
                 -- multiplications, that have occurred.
               }
  deriving ( Show )

zeroStatistics :: Statistics
zeroStatistics = Statistics { statAllocs = 0
                            , statNonLinearOps = 0 }
