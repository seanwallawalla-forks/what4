{-|
Module      : What4.Utils.AbstractDomains
Description : Abstract domains for term simplification
Copyright   : (c) Galois Inc, 2015-2020
License     : BSD3
Maintainer  : jhendrix@galois.com

This module declares a set of abstract domains used by the solver.
These are mostly interval domains on numeric types.

Since these abstract domains are baked directly into the term
representation, we want to get as much bang-for-buck as possible.
Thus, we prioritize compact representations and simple algorithms over
precision.
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

module What4.Utils.AbstractDomains
  ( ValueBound(..)
  , minValueBound
  , maxValueBound
    -- * ValueRange
  , ValueRange(..)
  , pattern MultiRange
  , unboundedRange
  , mapRange
  , rangeLowBound
  , rangeHiBound
  , singleRange
  , concreteRange
  , valueRange
  , addRange
  , negateRange
  , rangeScalarMul
  , mulRange
  , joinRange
  , asSingleRange
  , rangeCheckEq
  , rangeCheckLe
  , rangeMin
  , rangeMax
    -- * integer range operations
  , intAbsRange
  , intDivRange
  , intModRange
    -- * Boolean abstract value
  , absAnd
  , absOr

    -- * RealAbstractValue
  , RealAbstractValue(..)
  , ravUnbounded
  , ravSingle
  , ravConcreteRange
  , ravJoin
  , ravAdd
  , ravScalarMul
  , ravMul
  , ravCheckEq
  , ravCheckLe
    -- * StringAbstractValue
  , StringAbstractValue(..)
  , stringAbsJoin
  , stringAbsTop
  , stringAbsSingle
  , stringAbsOverlap
  , stringAbsLength
  , stringAbsConcat
  , stringAbsSubstring
  , stringAbsContains
  , stringAbsIsPrefixOf
  , stringAbsIsSuffixOf
  , stringAbsIndexOf
  , stringAbsEmpty

    -- * Abstractable
  , avTop
  , avSingle
  , avContains
  , AbstractValue
  , ConcreteValue
  , Abstractable(..)
  , withAbstractable
  , AbstractValueWrapper(..)
  , ConcreteValueWrapper(..)
  , HasAbsValue(..)
  ) where

import           Control.Exception (assert)
import           Data.Kind
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TraversableFC
import           Data.Ratio (denominator)

import           What4.BaseTypes
import           What4.Utils.BVDomain (BVDomain)
import qualified What4.Utils.BVDomain as BVD
import           What4.Utils.Complex
import           What4.Utils.StringLiteral

ctxZipWith3 :: (forall (x::k) . a x -> b x -> c x -> d x)
            -> Ctx.Assignment a (ctx::Ctx.Ctx k)
            -> Ctx.Assignment b ctx
            -> Ctx.Assignment c ctx
            -> Ctx.Assignment d ctx
ctxZipWith3 f a b c =
  Ctx.generate (Ctx.size a) $ \i ->
    f (a Ctx.! i) (b Ctx.! i) (c Ctx.! i)


------------------------------------------------------------------------
-- ValueBound

-- | A lower or upper bound on a value.
data ValueBound tp
   = Unbounded
   | Inclusive !tp
  deriving (Functor, Show, Eq, Ord)

instance Applicative ValueBound where
  pure = Inclusive
  Unbounded <*> _ = Unbounded
  _ <*> Unbounded = Unbounded
  Inclusive f <*> Inclusive v = Inclusive (f v)

instance Monad ValueBound where
  return = pure
  Unbounded >>= _ = Unbounded
  Inclusive v >>= f = f v

minValueBound :: Ord tp => ValueBound tp -> ValueBound tp -> ValueBound tp
minValueBound x y = min <$> x <*> y

maxValueBound :: Ord tp => ValueBound tp -> ValueBound tp -> ValueBound tp
maxValueBound x y = max <$> x <*> y

lowerBoundIsNegative :: (Ord tp, Num tp) => ValueBound tp -> Bool
lowerBoundIsNegative Unbounded = True
lowerBoundIsNegative (Inclusive y) = y <= 0

upperBoundIsNonNeg :: (Ord tp, Num tp) => ValueBound tp -> Bool
upperBoundIsNonNeg Unbounded = True
upperBoundIsNonNeg (Inclusive y) = y >= 0

------------------------------------------------------------------------
-- ValueRange support classes.

-- | Describes a range of values in a totally ordered set.
data ValueRange tp
  = SingleRange !tp
    -- ^ Indicates that range denotes a single value
  | UnboundedRange
    -- ^ The number is unconstrained.
  | MinRange !tp
    -- ^ The number is greater than or equal to the given lower bound.
  | MaxRange !tp
    -- ^ The number is less than or equal to the given upper bound.
  | IntervalRange !tp !tp
    -- ^ The number is between the given lower and upper bounds.

asMultiRange :: ValueRange tp -> Maybe (ValueBound tp, ValueBound tp)
asMultiRange r =
  case r of
    SingleRange _ -> Nothing
    UnboundedRange -> Just (Unbounded, Unbounded)
    MinRange lo -> Just (Inclusive lo, Unbounded)
    MaxRange hi -> Just (Unbounded, Inclusive hi)
    IntervalRange lo hi -> Just (Inclusive lo, Inclusive hi)

multiRange :: ValueBound tp -> ValueBound tp -> ValueRange tp
multiRange Unbounded Unbounded = UnboundedRange
multiRange Unbounded (Inclusive hi) = MaxRange hi
multiRange (Inclusive lo) Unbounded = MinRange lo
multiRange (Inclusive lo) (Inclusive hi) = IntervalRange lo hi

-- | Indicates that the number is somewhere between the given upper and lower bound.
pattern MultiRange :: ValueBound tp -> ValueBound tp -> ValueRange tp
pattern MultiRange lo hi <- (asMultiRange -> Just (lo, hi)) where
  MultiRange lo hi = multiRange lo hi

{-# COMPLETE SingleRange, MultiRange #-}

intAbsRange :: ValueRange Integer -> ValueRange Integer
intAbsRange r =
  case r of
    SingleRange x -> SingleRange (abs x)
    UnboundedRange -> MinRange 0
    MinRange lo
      | 0 <= lo -> r
      | otherwise -> MinRange 0
    MaxRange hi
      | hi <= 0 -> MinRange (negate hi)
      | otherwise -> MinRange 0
    IntervalRange lo hi
      | 0 <= lo -> r
      | hi <= 0 -> IntervalRange (negate hi) (negate lo)
      | otherwise -> IntervalRange 0 (max (abs lo) (abs hi))

-- | Compute an abstract range for integer division.  We are using the SMTLib
--   division operation, where the division is floor when the divisor is positive
--   and ceiling when the divisor is negative.  We compute the ranges assuming
--   that division by 0 doesn't happen, and we are allowed to return nonsense
--   ranges for these cases.
intDivRange :: ValueRange Integer -> ValueRange Integer -> ValueRange Integer
intDivRange (SingleRange x) (SingleRange y)
  | y > 0  = SingleRange (x `div` y)
  | y < 0  = SingleRange (negate (x `div` negate y))
intDivRange (MultiRange lo hi) (SingleRange y)
  | y >  0 = MultiRange
                   ((\x -> x `div` y) <$> lo)
                   ((\x -> x `div` y) <$> hi)
  | y <  0 = negateRange $ MultiRange
                    ((\x -> x `div` negate y) <$> lo)
                    ((\x -> x `div` negate y) <$> hi)

intDivRange x (MultiRange (Inclusive lo) hi)
  | 0 < lo = intDivAux x lo hi

intDivRange x (MultiRange lo (Inclusive hi))
  | hi < 0 = negateRange (intDivAux x (negate hi) (negate <$> lo))

-- The divisor interval contains 0, so we learn nothing
intDivRange _ _ = MultiRange Unbounded Unbounded


-- Here we get to assume 'lo' and 'hi' are strictly positive
intDivAux ::
  ValueRange Integer ->
  Integer -> ValueBound Integer ->
  ValueRange Integer
intDivAux x lo Unbounded = MultiRange lo' hi'
  where
  lo' = case rangeLowBound x of
           Unbounded -> Unbounded
           Inclusive z -> Inclusive (min 0 (div z lo))

  hi' = case rangeHiBound x of
           Unbounded   -> Unbounded
           Inclusive z -> Inclusive (max (-1) (div z lo))

intDivAux x lo (Inclusive hi) = MultiRange lo' hi'
  where
  lo' = case rangeLowBound x of
           Unbounded -> Unbounded
           Inclusive z -> Inclusive (min (div z hi) (div z lo))

  hi' = case rangeHiBound x of
           Unbounded   -> Unbounded
           Inclusive z -> Inclusive (max (div z hi) (div z lo))

intModRange :: ValueRange Integer -> ValueRange Integer -> ValueRange Integer
intModRange _ (SingleRange y) | y == 0 = MultiRange Unbounded Unbounded
intModRange (SingleRange x) (SingleRange y) = SingleRange (x `mod` abs y)
intModRange (MultiRange (Inclusive lo) (Inclusive hi)) (SingleRange y)
   | hi' - lo' == hi - lo = MultiRange (Inclusive lo') (Inclusive hi')
  where
  lo' = lo `mod` abs y
  hi' = hi `mod` abs y
intModRange _ y
  | Inclusive lo <- rangeLowBound yabs, lo > 0
  = MultiRange (Inclusive 0) (pred <$> rangeHiBound yabs)
  | otherwise
  = MultiRange Unbounded Unbounded
 where
 yabs = intAbsRange y


addRange :: Num tp => ValueRange tp -> ValueRange tp -> ValueRange tp
addRange (SingleRange x) y = mapRange (x+) y
addRange x (SingleRange y) = mapRange (y+) x
addRange UnboundedRange _ = UnboundedRange
addRange _ UnboundedRange = UnboundedRange
addRange (MinRange _) (MaxRange _) = UnboundedRange
addRange (MaxRange _) (MinRange _) = UnboundedRange
addRange (MinRange lx) (MinRange ly) = MinRange (lx+ly)
addRange (MaxRange ux) (MaxRange uy) = MaxRange (ux+uy)
addRange (MinRange lx) (IntervalRange ly _) = MinRange (lx+ly)
addRange (IntervalRange lx _) (MinRange ly) = MinRange (lx+ly)
addRange (MaxRange ux) (IntervalRange _ uy) = MaxRange (ux+uy)
addRange (IntervalRange _ ux) (MaxRange uy) = MaxRange (ux+uy)
addRange (IntervalRange lx ux) (IntervalRange ly uy) = IntervalRange (lx+ly) (ux+uy)

-- | Return 'Just True if the range only contains an integer, 'Just False' if it
-- contains no integers, and 'Nothing' if the range contains both integers and
-- non-integers.
rangeIsInteger :: ValueRange Rational -> Maybe Bool
rangeIsInteger (SingleRange x) = Just (denominator x == 1)
rangeIsInteger (MultiRange (Inclusive l) (Inclusive u))
  | floor l + 1 >= (ceiling u :: Integer)
  , denominator l /= 1
  , denominator u /= 1 = Just False
rangeIsInteger _ = Nothing

-- | Multiply a range by a scalar value
rangeScalarMul :: (Ord tp, Num tp) => tp -> ValueRange tp -> ValueRange tp
rangeScalarMul x r =
  case compare x 0 of
    LT -> mapAntiRange (x *) r
    EQ -> SingleRange 0
    GT -> mapRange (x *) r

negateRange :: (Num tp) => ValueRange tp -> ValueRange tp
negateRange = mapAntiRange negate

-- | Multiply two ranges together.
mulRange :: (Ord tp, Num tp) => ValueRange tp -> ValueRange tp -> ValueRange tp
mulRange (SingleRange x) y = rangeScalarMul x y
mulRange x (SingleRange y) = rangeScalarMul y x
mulRange (MultiRange lx ux) (MultiRange ly uy) = MultiRange lz uz
  where x_neg = lowerBoundIsNegative lx
        x_pos = upperBoundIsNonNeg ux
        y_neg = lowerBoundIsNegative ly
        y_pos = upperBoundIsNonNeg uy
             -- X can be negative and y can be positive, and also
             -- x can be positive and y can be negative.
        lz | x_neg && y_pos && x_pos && y_neg =
               minValueBound ((*) <$> lx <*> uy)
                             ((*) <$> ux <*> ly)
             -- X can be negative and Y can be positive, but
             -- either x must be negative (!x_pos) or y cannot be
             -- negative (!y_neg).
           | x_neg && y_pos = (*) <$> lx <*> uy
             -- X can be positive and Y can be negative, but
             -- either x must be positive (!x_neg) or y cannot be
             -- positive (!y_pos).
           | x_pos && y_neg = (*) <$> ux <*> ly
             -- Both x and y must be negative.
           | x_neg = assert (not x_pos && not y_pos) $ (*) <$> ux <*> uy
             -- Both x and y must be positive.
           | otherwise = (*) <$> lx <*> ly
        uz | x_neg && y_neg && x_pos && y_pos =
             maxValueBound ((*) <$> lx <*> ly)
                           ((*) <$> ux <*> uy)
             -- Both x and y can be negative, but they both can't be positive.
           | x_neg && y_neg = (*) <$> lx <*> ly
             -- Both x and y can be positive, but they both can't be negative.
           | x_pos && y_pos = (*) <$> ux <*> uy
             -- x must be positive and y must be negative.
           | x_pos = (*) <$> lx <*> uy
             -- x must be negative and y must be positive.
           | otherwise = (*) <$> ux <*> ly

-- | Return lower bound of range.
rangeLowBound :: ValueRange tp -> ValueBound tp
rangeLowBound (SingleRange x) = Inclusive x
rangeLowBound (MultiRange l _) = l

-- | Return upper bound of range.
rangeHiBound :: ValueRange tp -> ValueBound tp
rangeHiBound (SingleRange x) = Inclusive x
rangeHiBound (MultiRange _ u) = u

-- | Compute the smallest range containing both ranges.
joinRange :: Ord tp => ValueRange tp -> ValueRange tp -> ValueRange tp
joinRange (SingleRange x) (SingleRange y)
  | x == y = SingleRange x
joinRange x y = MultiRange (minValueBound lx ly) (maxValueBound ux uy)
  where lx = rangeLowBound x
        ux = rangeHiBound x
        ly = rangeLowBound y
        uy = rangeHiBound y

-- | Return true if value ranges overlap.
rangeOverlap :: Ord tp => ValueRange tp -> ValueRange tp -> Bool
rangeOverlap x y
   -- first range is before second.
  | Inclusive ux <- rangeHiBound x
  , Inclusive ly <- rangeLowBound y
  , ux < ly = False

  -- second range is before first.
  | Inclusive lx <- rangeLowBound x
  , Inclusive uy <- rangeHiBound y
  , uy < lx = False

  -- Ranges share some elements.
  | otherwise = True

-- | Return maybe Boolean if range is equal, is not equal, or indeterminant.
rangeCheckEq :: Ord tp => ValueRange tp -> ValueRange tp -> Maybe Bool
rangeCheckEq x y
    -- If ranges do not overlap return false.
  | not (rangeOverlap x y) = Just False
    -- If they are both single values, then result can be determined.
  | Just cx <- asSingleRange x
  , Just cy <- asSingleRange y
  = Just (cx == cy)
    -- Otherwise result is indeterminant.
  | otherwise = Nothing


rangeCheckLe :: Ord tp => ValueRange tp -> ValueRange tp -> Maybe Bool
rangeCheckLe x y
    -- First range upper bound is below lower bound of second.
  | Inclusive ux <- rangeHiBound x
  , Inclusive ly <- rangeLowBound y
  , ux <= ly = Just True

    -- First range lower bound is above upper bound of second.
  | Inclusive lx <- rangeLowBound x
  , Inclusive uy <- rangeHiBound y
  , uy <  lx = Just False

  | otherwise = Nothing

-- | Defines a unbounded value range.
unboundedRange :: ValueRange tp
unboundedRange = UnboundedRange

-- | Defines a unbounded value range.
concreteRange :: Eq tp => tp -> tp -> ValueRange tp
concreteRange x y
  | x == y = SingleRange x
  | otherwise = IntervalRange x y

-- | Defines a value range containing a single element.
singleRange :: tp -> ValueRange tp
singleRange v = SingleRange v

-- | Define a value range with the given bounds
valueRange :: Eq tp => ValueBound tp -> ValueBound tp -> ValueRange tp
valueRange (Inclusive x) (Inclusive y)
  | x == y = SingleRange x
valueRange x y = MultiRange x y

-- | Check if range is just a single element.
asSingleRange :: ValueRange tp -> Maybe tp
asSingleRange (SingleRange x) = Just x
asSingleRange _ = Nothing

-- | Map a monotonic function over a range.
mapRange :: (a -> b) -> ValueRange a -> ValueRange b
mapRange f r =
  case r of
    SingleRange x -> SingleRange (f x)
    UnboundedRange -> UnboundedRange
    MinRange l -> MinRange (f l)
    MaxRange h -> MaxRange (f h)
    IntervalRange l h -> IntervalRange (f l) (f h)

-- | Map an anti-monotonic function over a range.
mapAntiRange :: (a -> b) -> ValueRange a -> ValueRange b
mapAntiRange f r =
  case r of
    SingleRange x -> SingleRange (f x)
    UnboundedRange -> UnboundedRange
    MinRange l -> MaxRange (f l)
    MaxRange h -> MinRange (f h)
    IntervalRange l h -> IntervalRange (f h) (f l)

------------------------------------------------------------------------
-- AbstractValue definition.

-- Contains range for rational and whether value must be an integer.
data RealAbstractValue = RAV { ravRange :: !(ValueRange Rational)
                             , ravIsInteger :: !(Maybe Bool)
                             }

ravUnbounded :: RealAbstractValue
ravUnbounded = (RAV unboundedRange Nothing)

ravSingle :: Rational -> RealAbstractValue
ravSingle x = RAV (singleRange x) (Just $! denominator x == 1)

-- | Range accepting everything between lower and upper bound.
ravConcreteRange :: Rational -- ^ Lower bound
                 -> Rational -- ^ Upper bound
                 -> RealAbstractValue
ravConcreteRange l h = RAV (concreteRange l h) (Just $! b)
  where -- Return true if this is a singleton.
        b = l == h && denominator l == 1

-- | Add two real abstract values.
ravAdd :: RealAbstractValue -> RealAbstractValue -> RealAbstractValue
ravAdd (RAV xr xi) (RAV yr yi) = RAV zr zi
  where zr = addRange xr yr
        zi | (xi,yi) == (Just True, Just True) = Just True
           | otherwise = rangeIsInteger zr

ravScalarMul :: Rational -> RealAbstractValue -> RealAbstractValue
ravScalarMul x (RAV yr yi) = RAV zr zi
  where zr = rangeScalarMul x yr
        zi | denominator x == 1 && yi == Just True = Just True
           | otherwise = rangeIsInteger zr


ravMul :: RealAbstractValue -> RealAbstractValue -> RealAbstractValue
ravMul (RAV xr xi) (RAV yr yi) = RAV zr zi
  where zr = mulRange xr yr
        zi | (xi,yi) == (Just True, Just True) = Just True
           | otherwise = rangeIsInteger zr

ravJoin :: RealAbstractValue -> RealAbstractValue -> RealAbstractValue
ravJoin (RAV xr xi) (RAV yr yi) = RAV (joinRange xr yr) zi
  where zi | xi == yi = xi
           | otherwise = Nothing

ravCheckEq :: RealAbstractValue -> RealAbstractValue -> Maybe Bool
ravCheckEq (RAV xr _) (RAV yr _) = rangeCheckEq xr yr

ravCheckLe :: RealAbstractValue -> RealAbstractValue -> Maybe Bool
ravCheckLe (RAV xr _) (RAV yr _) = rangeCheckLe xr yr

-- Computing AbstractValue

absAnd :: Maybe Bool -> Maybe Bool -> Maybe Bool
absAnd (Just False) _ = Just False
absAnd (Just True) y = y
absAnd _ (Just False) = Just False
absAnd x (Just True) = x
absAnd Nothing Nothing = Nothing

absOr :: Maybe Bool -> Maybe Bool -> Maybe Bool
absOr (Just False) y = y
absOr (Just True)  _ = Just True
absOr x (Just False) = x
absOr _ (Just True)  = Just True
absOr Nothing Nothing = Nothing


rangeMax :: Ord a => ValueRange a -> ValueRange a -> ValueRange a
rangeMax x y = valueRange lo hi
 where
 lo = case (rangeLowBound x, rangeLowBound y) of
        (Unbounded, b) -> b
        (a, Unbounded) -> a
        (Inclusive a, Inclusive b) -> Inclusive (max a b)

 hi = case (rangeHiBound x, rangeHiBound y) of
         (Unbounded, _) -> Unbounded
         (_, Unbounded) -> Unbounded
         (Inclusive a, Inclusive b) -> Inclusive (max a b)


rangeMin :: Ord a => ValueRange a -> ValueRange a -> ValueRange a
rangeMin x y = valueRange lo hi
 where
 lo = case (rangeLowBound x, rangeLowBound y) of
        (Unbounded, _) -> Unbounded
        (_, Unbounded) -> Unbounded
        (Inclusive a, Inclusive b) -> Inclusive (min a b)

 hi = case (rangeHiBound x, rangeHiBound y) of
         (Unbounded, b) -> b
         (a, Unbounded) -> a
         (Inclusive a, Inclusive b) -> Inclusive (min a b)


------------------------------------------------------
-- String abstract domain

-- | The string abstract domain tracks an interval
--   range for the length of the string.
newtype StringAbstractValue =
  StringAbs
  { _stringAbsLength :: ValueRange Integer
     -- ^ The length of the string falls in this range
  }

stringAbsTop :: StringAbstractValue
stringAbsTop = StringAbs (MultiRange (Inclusive 0) Unbounded)

stringAbsEmpty :: StringAbstractValue
stringAbsEmpty = StringAbs (singleRange 0)

stringAbsJoin :: StringAbstractValue -> StringAbstractValue -> StringAbstractValue
stringAbsJoin (StringAbs lenx) (StringAbs leny) = StringAbs (joinRange lenx leny)

stringAbsSingle :: StringLiteral si -> StringAbstractValue
stringAbsSingle lit = StringAbs (singleRange (toInteger (stringLitLength lit)))

stringAbsOverlap :: StringAbstractValue -> StringAbstractValue -> Bool
stringAbsOverlap (StringAbs lenx) (StringAbs leny) = rangeOverlap lenx leny

stringAbsCheckEq :: StringAbstractValue -> StringAbstractValue -> Maybe Bool
stringAbsCheckEq (StringAbs lenx) (StringAbs leny)
  | Just 0 <- asSingleRange lenx
  , Just 0 <- asSingleRange leny
  = Just True

  | not (rangeOverlap lenx leny)
  = Just False

  | otherwise
  = Nothing

stringAbsConcat :: StringAbstractValue -> StringAbstractValue -> StringAbstractValue
stringAbsConcat (StringAbs lenx) (StringAbs leny) = StringAbs (addRange lenx leny)

stringAbsSubstring :: StringAbstractValue -> ValueRange Integer -> ValueRange Integer -> StringAbstractValue
stringAbsSubstring (StringAbs s) off len
  -- empty string if len is negative
  | Just False <- rangeCheckLe (singleRange 0) len = StringAbs (singleRange 0)
  -- empty string if off is negative
  | Just False <- rangeCheckLe (singleRange 0) off = StringAbs (singleRange 0)
  -- empty string if off is out of bounds
  | Just True <- rangeCheckLe s off = StringAbs (singleRange 0)

  | otherwise =
      let -- clamp off at 0
          off' = rangeMax (singleRange 0) off
          -- clamp len at 0
          len' = rangeMax (singleRange 0) len
          -- subtract off' from the length of s, clamp to 0
          s'   = rangeMax (singleRange 0) (addRange s (negateRange off'))
          -- result is the minimum of the length requested and the length
          -- of the string after removing the prefix
       in StringAbs (rangeMin len' s')

stringAbsContains :: StringAbstractValue -> StringAbstractValue -> Maybe Bool
stringAbsContains = couldContain

stringAbsIsPrefixOf :: StringAbstractValue -> StringAbstractValue -> Maybe Bool
stringAbsIsPrefixOf = flip couldContain

stringAbsIsSuffixOf :: StringAbstractValue -> StringAbstractValue -> Maybe Bool
stringAbsIsSuffixOf = flip couldContain

couldContain :: StringAbstractValue -> StringAbstractValue -> Maybe Bool
couldContain (StringAbs lenx) (StringAbs leny)
  | Just False <- rangeCheckLe leny lenx = Just False
  | otherwise = Nothing

stringAbsIndexOf :: StringAbstractValue -> StringAbstractValue -> ValueRange Integer -> ValueRange Integer
stringAbsIndexOf (StringAbs lenx) (StringAbs leny) k
  | Just False <- rangeCheckLe (singleRange 0) k = SingleRange (-1)
  | Just False <- rangeCheckLe (addRange leny k) lenx = SingleRange (-1)
  | otherwise = MultiRange (Inclusive (-1)) (rangeHiBound rng)

  where
  -- possible values that the final offset could have if the substring exists anywhere
  rng = rangeMax (singleRange 0) (addRange lenx (negateRange leny))

stringAbsLength :: StringAbstractValue -> ValueRange Integer
stringAbsLength (StringAbs len) = len

-- | An abstract value represents a disjoint st of values.
type family AbstractValue (tp::BaseType) :: Type where
  AbstractValue BaseBoolType = Maybe Bool
  AbstractValue BaseIntegerType = ValueRange Integer
  AbstractValue BaseRealType = RealAbstractValue
  AbstractValue (BaseStringType si) = StringAbstractValue
  AbstractValue (BaseBVType w) = BVDomain w
  AbstractValue (BaseFloatType _) = ()
  AbstractValue BaseComplexType = Complex RealAbstractValue
  AbstractValue (BaseArrayType idx b) = AbstractValue b
  AbstractValue (BaseStructType ctx) = Ctx.Assignment AbstractValueWrapper ctx


-- | A utility class for values that contain abstract values
class HasAbsValue f where
  getAbsValue :: f tp -> AbstractValue tp

newtype AbstractValueWrapper tp
      = AbstractValueWrapper { unwrapAV :: AbstractValue tp }

type family ConcreteValue (tp::BaseType) :: Type where
  ConcreteValue BaseBoolType = Bool
  ConcreteValue BaseIntegerType = Integer
  ConcreteValue BaseRealType = Rational
  ConcreteValue (BaseStringType si) = StringLiteral si
  ConcreteValue (BaseBVType w) = Integer
  ConcreteValue (BaseFloatType _) = ()
  ConcreteValue BaseComplexType = Complex Rational
  ConcreteValue (BaseArrayType idx b) = ()
  ConcreteValue (BaseStructType ctx) = Ctx.Assignment ConcreteValueWrapper ctx

newtype ConcreteValueWrapper tp
      = ConcreteValueWrapper { unwrapCV :: ConcreteValue tp }

-- | Create an abstract value that contains every concrete value.
avTop :: BaseTypeRepr tp -> AbstractValue tp
avTop tp =
  case tp of
    BaseBoolRepr    -> Nothing
    BaseIntegerRepr -> unboundedRange
    BaseRealRepr    -> ravUnbounded
    BaseComplexRepr -> ravUnbounded :+ ravUnbounded
    BaseStringRepr _ -> stringAbsTop
    BaseBVRepr w    -> BVD.any w
    BaseFloatRepr{} -> ()
    BaseArrayRepr _a b -> avTop b
    BaseStructRepr flds -> fmapFC (\etp -> AbstractValueWrapper (avTop etp)) flds

-- | Create an abstract value that contains the given concrete value.
avSingle :: BaseTypeRepr tp -> ConcreteValue tp -> AbstractValue tp
avSingle tp =
  case tp of
    BaseBoolRepr -> Just
    BaseIntegerRepr -> singleRange
    BaseRealRepr -> ravSingle
    BaseStringRepr _ -> stringAbsSingle
    BaseComplexRepr -> fmap ravSingle
    BaseBVRepr w -> BVD.singleton w
    BaseFloatRepr _ -> \_ -> ()
    BaseArrayRepr _a b -> \_ -> avTop b
    BaseStructRepr flds -> \vals ->
      Ctx.zipWith
        (\ftp v -> AbstractValueWrapper (avSingle ftp (unwrapCV v)))
        flds
        vals

------------------------------------------------------------------------
-- Abstractable

class Abstractable (tp::BaseType) where

  -- | Take the union of the two abstract values.
  avJoin     :: BaseTypeRepr tp -> AbstractValue tp -> AbstractValue tp -> AbstractValue tp

  -- | Returns true if the abstract values could contain a common concrete
  -- value.
  avOverlap  :: BaseTypeRepr tp -> AbstractValue tp -> AbstractValue tp -> Bool

  -- | Check equality on two abstract values.  Return true or false if we can definitively
  --   determine the equality of the two elements, and nothing otherwise.
  avCheckEq :: BaseTypeRepr tp -> AbstractValue tp -> AbstractValue tp -> Maybe Bool

avJoin' :: BaseTypeRepr tp
        -> AbstractValueWrapper tp
        -> AbstractValueWrapper tp
        -> AbstractValueWrapper tp
avJoin' tp x y = withAbstractable tp $
  AbstractValueWrapper $ avJoin tp (unwrapAV x) (unwrapAV y)

-- Abstraction captures whether Boolean is constant true or false or Nothing
instance Abstractable BaseBoolType where
  avJoin _ x y | x == y = x
               | otherwise = Nothing

  avOverlap _ (Just x) (Just y) | x /= y = False
  avOverlap _ _ _ = True

  avCheckEq _ (Just x) (Just y) = Just (x == y)
  avCheckEq _ _ _ = Nothing

instance Abstractable (BaseStringType si) where
  avJoin _     = stringAbsJoin
  avOverlap _  = stringAbsOverlap
  avCheckEq _  = stringAbsCheckEq

-- Integers have a lower and upper bound associated with them.
instance Abstractable BaseIntegerType where
  avJoin _ = joinRange
  avOverlap _ = rangeOverlap
  avCheckEq _ = rangeCheckEq

-- Real numbers  have a lower and upper bound associated with them.
instance Abstractable BaseRealType where
  avJoin _ = ravJoin
  avOverlap _ x y = rangeOverlap (ravRange x) (ravRange y)
  avCheckEq _ = ravCheckEq

-- Bitvectors always have a lower and upper bound (represented as unsigned numbers)
instance (1 <= w) => Abstractable (BaseBVType w) where
  avJoin (BaseBVRepr _) = BVD.union
  avOverlap _ = BVD.domainsOverlap
  avCheckEq _ = BVD.eq

instance Abstractable (BaseFloatType fpp) where
  avJoin _ _ _ = ()
  avOverlap _ _ _ = True
  avCheckEq _ _ _ = Nothing

instance Abstractable BaseComplexType where
  avJoin _ (r1 :+ i1) (r2 :+ i2) = (ravJoin r1 r2) :+ (ravJoin i1 i2)
  avOverlap _ (r1 :+ i1) (r2 :+ i2) = rangeOverlap (ravRange r1) (ravRange r2)
                                   && rangeOverlap (ravRange i1) (ravRange i2)
  avCheckEq _ (r1 :+ i1) (r2 :+ i2)
    = combineEqCheck
        (rangeCheckEq (ravRange r1) (ravRange r2))
        (rangeCheckEq (ravRange i1) (ravRange i2))

instance Abstractable (BaseArrayType idx b) where
  avJoin (BaseArrayRepr _ b) x y = withAbstractable b $ avJoin b x y
  avOverlap (BaseArrayRepr _ b) x y = withAbstractable b $ avOverlap b x y
  avCheckEq (BaseArrayRepr _ b) x y = withAbstractable b $ avCheckEq b x y

combineEqCheck :: Maybe Bool -> Maybe Bool -> Maybe Bool
combineEqCheck (Just False) _ = Just False
combineEqCheck (Just True)  y = y
combineEqCheck _ (Just False) = Just False
combineEqCheck x (Just True)  = x
combineEqCheck _ _            = Nothing

instance Abstractable (BaseStructType ctx) where
  avJoin (BaseStructRepr flds) x y = ctxZipWith3 avJoin' flds x y
  avOverlap (BaseStructRepr flds) x y = Ctx.forIndex (Ctx.size flds) f True
    where f :: Bool -> Ctx.Index ctx tp -> Bool
          f b i = withAbstractable tp (avOverlap tp (unwrapAV u) (unwrapAV v)) && b
            where tp = flds Ctx.! i
                  u  = x Ctx.! i
                  v  = y Ctx.! i

  avCheckEq (BaseStructRepr flds) x y = Ctx.forIndex (Ctx.size flds) f (Just True)
    where f :: Maybe Bool -> Ctx.Index ctx tp -> Maybe Bool
          f b i = combineEqCheck b (withAbstractable tp (avCheckEq tp (unwrapAV u) (unwrapAV v)))
            where tp = flds Ctx.! i
                  u  = x Ctx.! i
                  v  = y Ctx.! i

withAbstractable
   :: BaseTypeRepr bt
   -> (Abstractable bt => a)
   -> a
withAbstractable bt k =
  case bt of
    BaseBoolRepr -> k
    BaseBVRepr _w -> k
    BaseIntegerRepr -> k
    BaseStringRepr _ -> k
    BaseRealRepr -> k
    BaseComplexRepr -> k
    BaseArrayRepr _a _b -> k
    BaseStructRepr _flds -> k
    BaseFloatRepr _fpp -> k

-- | Returns true if the concrete value is a member of the set represented
-- by the abstract value.
avContains :: BaseTypeRepr tp -> ConcreteValue tp -> AbstractValue tp -> Bool
avContains tp = withAbstractable tp $ \x y -> avOverlap tp (avSingle tp x) y
