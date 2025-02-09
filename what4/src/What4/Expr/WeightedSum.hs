{-|
Module      : What4.Expr.WeightedSum
Description : Representations for weighted sums and products in semirings
Copyright   : (c) Galois Inc, 2015-2020
License     : BSD3
Maintainer  : jhendrix@galois.com

Declares a weighted sum type used for representing sums over variables and an offset
in one of the supported semirings.  This module also implements a representation of
semiring products.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wwarn #-}
module What4.Expr.WeightedSum
  ( -- * Utilities
    Tm
    -- * Weighted sums
  , WeightedSum
  , sumRepr
  , sumOffset
  , sumAbsValue
  , constant
  , var
  , scaledVar
  , asConstant
  , asVar
  , asWeightedVar
  , asAffineVar
  , isZero
  , traverseVars
  , traverseCoeffs
  , add
  , addVar
  , addVars
  , addConstant
  , scale
  , eval
  , evalM
  , extractCommon
  , fromTerms
  , transformSum
  , reduceIntSumMod

    -- * Ring products
  , SemiRingProduct
  , traverseProdVars
  , nullProd
  , asProdVar
  , prodRepr
  , prodVar
  , prodAbsValue
  , prodMul
  , prodEval
  , prodEvalM
  , prodContains
  ) where

import           Control.Lens
import           Control.Monad.State
import qualified Data.BitVector.Sized as BV
import           Data.Hashable
import           Data.Kind
import           Data.List (foldl')
import           Data.Maybe
import           Data.Parameterized.Classes

import           What4.BaseTypes
import qualified What4.SemiRing as SR
import           What4.Utils.AnnotatedMap (AnnotatedMap)
import qualified What4.Utils.AnnotatedMap as AM
import qualified What4.Utils.AbstractDomains as AD
import qualified What4.Utils.BVDomain.Arith as A
import qualified What4.Utils.BVDomain.XOR as X
import qualified What4.Utils.BVDomain as BVD

import           What4.Utils.IncrHash

--------------------------------------------------------------------------------

data SRAbsValue :: SR.SemiRing -> Type where
  SRAbsIntAdd  :: !(AD.ValueRange Integer)  -> SRAbsValue SR.SemiRingInteger
  SRAbsRealAdd :: !AD.RealAbstractValue     -> SRAbsValue SR.SemiRingReal
  SRAbsBVAdd   :: (1 <= w) => !(A.Domain w) -> SRAbsValue (SR.SemiRingBV SR.BVArith w)
  SRAbsBVXor   :: (1 <= w) => !(X.Domain w) -> SRAbsValue (SR.SemiRingBV SR.BVBits w)

instance Semigroup (SRAbsValue sr) where
  SRAbsIntAdd  x <> SRAbsIntAdd  y = SRAbsIntAdd  (AD.addRange x y)
  SRAbsRealAdd x <> SRAbsRealAdd y = SRAbsRealAdd (AD.ravAdd x y)
  SRAbsBVAdd   x <> SRAbsBVAdd   y = SRAbsBVAdd   (A.add x y)
  SRAbsBVXor   x <> SRAbsBVXor   y = SRAbsBVXor   (X.xor x y)


(.**) :: SRAbsValue sr -> SRAbsValue sr -> SRAbsValue sr
SRAbsIntAdd  x .** SRAbsIntAdd  y = SRAbsIntAdd  (AD.mulRange x y)
SRAbsRealAdd x .** SRAbsRealAdd y = SRAbsRealAdd (AD.ravMul x y)
SRAbsBVAdd   x .** SRAbsBVAdd   y = SRAbsBVAdd   (A.mul x y)
SRAbsBVXor   x .** SRAbsBVXor   y = SRAbsBVXor   (X.and x y)

abstractTerm ::
  AD.HasAbsValue f =>
  SR.SemiRingRepr sr -> SR.Coefficient sr -> f (SR.SemiRingBase sr) -> SRAbsValue sr
abstractTerm sr c e =
  case sr of
    SR.SemiRingIntegerRepr -> SRAbsIntAdd (AD.rangeScalarMul c (AD.getAbsValue e))
    SR.SemiRingRealRepr    -> SRAbsRealAdd (AD.ravScalarMul c (AD.getAbsValue e))
    SR.SemiRingBVRepr fv w ->
      case fv of
        SR.BVArithRepr ->
          -- A.scale expects a signed integer coefficient
          SRAbsBVAdd (A.scale (BV.asSigned w c) (BVD.asArithDomain (AD.getAbsValue e)))
        SR.BVBitsRepr  -> SRAbsBVXor (X.and_scalar (BV.asUnsigned c) (BVD.asXorDomain (AD.getAbsValue e)))

abstractVal :: AD.HasAbsValue f => SR.SemiRingRepr sr -> f (SR.SemiRingBase sr) -> SRAbsValue sr
abstractVal sr e =
  case sr of
    SR.SemiRingIntegerRepr -> SRAbsIntAdd (AD.getAbsValue e)
    SR.SemiRingRealRepr    -> SRAbsRealAdd (AD.getAbsValue e)
    SR.SemiRingBVRepr fv _w ->
      case fv of
        SR.BVArithRepr -> SRAbsBVAdd (BVD.asArithDomain (AD.getAbsValue e))
        SR.BVBitsRepr  -> SRAbsBVXor (BVD.asXorDomain (AD.getAbsValue e))

abstractScalar ::
  SR.SemiRingRepr sr -> SR.Coefficient sr -> SRAbsValue sr
abstractScalar sr c =
  case sr of
    SR.SemiRingIntegerRepr -> SRAbsIntAdd (AD.SingleRange c)
    SR.SemiRingRealRepr    -> SRAbsRealAdd (AD.ravSingle c)
    SR.SemiRingBVRepr fv w ->
      case fv of
        SR.BVArithRepr -> SRAbsBVAdd (A.singleton w (BV.asUnsigned c))
        SR.BVBitsRepr  -> SRAbsBVXor (X.singleton w (BV.asUnsigned c))

fromSRAbsValue ::
  SRAbsValue sr -> AD.AbstractValue (SR.SemiRingBase sr)
fromSRAbsValue v =
  case v of
    SRAbsIntAdd  x -> x
    SRAbsRealAdd x -> x
    SRAbsBVAdd   x -> BVD.BVDArith x
    SRAbsBVXor   x -> BVD.fromXorDomain x

--------------------------------------------------------------------------------

type Tm f = (HashableF f, OrdF f, AD.HasAbsValue f)

newtype WrapF (f :: BaseType -> Type) (i :: SR.SemiRing) = WrapF (f (SR.SemiRingBase i))

instance OrdF f => Ord (WrapF f i) where
  compare (WrapF x) (WrapF y) = toOrdering $ compareF x y

instance TestEquality f => Eq (WrapF f i) where
  (WrapF x) == (WrapF y) = isJust $ testEquality x y

instance (HashableF f, TestEquality f) => Hashable (WrapF f i) where
  hashWithSalt s (WrapF x) = hashWithSaltF s x

traverseWrap :: Functor m => (f (SR.SemiRingBase i) -> m (g (SR.SemiRingBase i))) -> WrapF f i -> m (WrapF g i)
traverseWrap f (WrapF x) = WrapF <$> f x

-- | The annotation type used for the annotated map. It consists of
-- the hash value and the abstract domain representation of type @d@
-- for each submap.
data Note sr = Note !IncrHash !(SRAbsValue sr)

instance Semigroup (Note sr) where
  Note h1 d1 <> Note h2 d2 = Note (h1 <> h2) (d1 <> d2)

data ProdNote sr = ProdNote !IncrHash !(SRAbsValue sr)

-- | The annotation type used for the annotated map for products.
-- It consists of the hash value and the abstract domain representation
-- of type @d@ for each submap.  NOTE! that the multiplication operation
-- on abstract values is not always associative.  This, however, is
-- acceptable because all associative groupings lead to sound (but perhaps not best)
-- approximate values.

instance Semigroup (ProdNote sr) where
  ProdNote h1 d1 <> ProdNote h2 d2 = ProdNote (h1 <> h2) (d1 .** d2)

-- | Construct the annotation for a single map entry.
mkNote ::
  (HashableF f, AD.HasAbsValue f) =>
  SR.SemiRingRepr sr -> SR.Coefficient sr -> f (SR.SemiRingBase sr) -> Note sr
mkNote sr c t = Note (mkIncrHash h) d
  where
    h = SR.sr_hashWithSalt sr (hashF t) c
    d = abstractTerm sr c t

mkProdNote ::
  (HashableF f, AD.HasAbsValue f) =>
  SR.SemiRingRepr sr ->
  SR.Occurrence sr ->
  f (SR.SemiRingBase sr) ->
  ProdNote sr
mkProdNote sr occ t = ProdNote (mkIncrHash h) d
  where
    h = SR.occ_hashWithSalt sr (hashF t) occ
    v = abstractVal sr t
    power = fromIntegral (SR.occ_count sr occ)
    d = go (power - 1) v

    go (n::Integer) x
      | n > 0     = go (n-1) (v .** x)
      | otherwise = x

type SumMap f sr  = AnnotatedMap (WrapF f sr) (Note sr) (SR.Coefficient sr)
type ProdMap f sr = AnnotatedMap (WrapF f sr) (ProdNote sr) (SR.Occurrence sr)

insertSumMap ::
  Tm f =>
  SR.SemiRingRepr sr ->
  SR.Coefficient sr -> f (SR.SemiRingBase sr) -> SumMap f sr -> SumMap f sr
insertSumMap sr c t = AM.alter f (WrapF t)
  where
    f Nothing = Just (mkNote sr c t, c)
    f (Just (_, c0))
      | SR.eq sr (SR.zero sr) c' = Nothing
      | otherwise = Just (mkNote sr c' t, c')
      where c' = SR.add sr c0 c

singletonSumMap ::
  Tm f =>
  SR.SemiRingRepr sr ->
  SR.Coefficient sr -> f (SR.SemiRingBase sr) -> SumMap f sr
singletonSumMap sr c t = AM.singleton (WrapF t) (mkNote sr c t) c

singletonProdMap ::
  Tm f =>
  SR.SemiRingRepr sr ->
  SR.Occurrence sr ->
  f (SR.SemiRingBase sr) ->
  ProdMap f sr
singletonProdMap sr occ t = AM.singleton (WrapF t) (mkProdNote sr occ t) occ

fromListSumMap ::
  Tm f =>
  SR.SemiRingRepr sr ->
  [(f (SR.SemiRingBase sr), SR.Coefficient sr)] -> SumMap f sr
fromListSumMap _ [] = AM.empty
fromListSumMap sr ((t, c) : xs) = insertSumMap sr c t (fromListSumMap sr xs)

toListSumMap :: SumMap f sr -> [(f (SR.SemiRingBase sr), SR.Coefficient sr)]
toListSumMap am = [ (t, c) | (WrapF t, c) <- AM.toList am ]

-- | A weighted sum of semiring values.  Mathematically, this represents
--   an affine operation on the underlying expressions.
data WeightedSum (f :: BaseType -> Type) (sr :: SR.SemiRing)
   = WeightedSum { _sumMap     :: !(SumMap f sr)
                 , _sumOffset  :: !(SR.Coefficient sr)
                 , sumRepr     :: !(SR.SemiRingRepr sr)
                     -- ^ Runtime representation of the semiring for this sum.
                 }

-- | A product of semiring values.
data SemiRingProduct (f :: BaseType -> Type) (sr :: SR.SemiRing)
   = SemiRingProduct { _prodMap  :: !(ProdMap f sr)
                     , prodRepr  :: !(SR.SemiRingRepr sr)
                         -- ^ Runtime representation of the semiring for this product
                     }

-- | Return the hash of the 'SumMap' part of the 'WeightedSum'.
sumMapHash :: OrdF f => WeightedSum f sr -> IncrHash
sumMapHash x =
  case AM.annotation (_sumMap x) of
    Nothing -> mempty
    Just (Note h _) -> h

prodMapHash :: OrdF f => SemiRingProduct f sr -> IncrHash
prodMapHash pd =
  case AM.annotation (_prodMap pd) of
    Nothing -> mempty
    Just (ProdNote h _) -> h

sumAbsValue :: OrdF f => WeightedSum f sr -> AD.AbstractValue (SR.SemiRingBase sr)
sumAbsValue wsum =
  fromSRAbsValue $
  case AM.annotation (_sumMap wsum) of
    Nothing         -> absOffset
    Just (Note _ v) -> absOffset <> v
  where
    absOffset = abstractScalar (sumRepr wsum) (_sumOffset wsum)

instance OrdF f => TestEquality (SemiRingProduct f) where
  testEquality x y
    | prodMapHash x /= prodMapHash y = Nothing
    | otherwise =
        do Refl <- testEquality (prodRepr x) (prodRepr y)
           unless (AM.eqBy (SR.occ_eq (prodRepr x)) (_prodMap x) (_prodMap y)) Nothing
           return Refl

instance OrdF f => Eq (SemiRingProduct f sr) where
  x == y = isJust (testEquality x y)

instance OrdF f => TestEquality (WeightedSum f) where
  testEquality x y
    | sumMapHash x /= sumMapHash y = Nothing
    | otherwise =
         do Refl <- testEquality (sumRepr x) (sumRepr y)
            unless (SR.eq (sumRepr x) (_sumOffset x) (_sumOffset y)) Nothing
            unless (AM.eqBy (SR.eq (sumRepr x)) (_sumMap x) (_sumMap y)) Nothing
            return Refl

instance OrdF f => Eq (WeightedSum f sr) where
  x == y = isJust (testEquality x y)


-- | Created a weighted sum directly from a map and constant.
--
-- Note. When calling this, one should ensure map values equal to '0'
-- have been removed.
unfilteredSum ::
  SR.SemiRingRepr sr ->
  SumMap f sr ->
  SR.Coefficient sr ->
  WeightedSum f sr
unfilteredSum sr m c = WeightedSum m c sr

-- | Retrieve the mapping from terms to coefficients.
sumMap :: Lens' (WeightedSum f sr) (SumMap f sr)
sumMap = lens _sumMap (\w m -> w{ _sumMap = m })

-- | Retrieve the constant addend of the weighted sum.
sumOffset :: Lens' (WeightedSum f sr) (SR.Coefficient sr)
sumOffset = lens _sumOffset (\s v -> s { _sumOffset = v })

instance OrdF f => Hashable (WeightedSum f sr) where
  hashWithSalt s0 w =
    hashWithSalt (SR.sr_hashWithSalt (sumRepr w) s0 (_sumOffset w)) (sumMapHash w)

instance OrdF f => Hashable (SemiRingProduct f sr) where
  hashWithSalt s0 w = hashWithSalt s0 (prodMapHash w)

-- | Attempt to parse a weighted sum as a constant.
asConstant :: WeightedSum f sr -> Maybe (SR.Coefficient sr)
asConstant w
  | AM.null (_sumMap w) = Just (_sumOffset w)
  | otherwise = Nothing

-- | Return true if a weighted sum is equal to constant 0.
isZero :: SR.SemiRingRepr sr -> WeightedSum f sr -> Bool
isZero sr s =
   case asConstant s of
     Just c  -> SR.sr_compare sr (SR.zero sr) c == EQ
     Nothing -> False

-- | Attempt to parse a weighted sum as a single expression with a coefficient and offset.
--   @asAffineVar w = Just (c,r,o)@ when @denotation(w) = c*r + o@.
asAffineVar :: WeightedSum f sr -> Maybe (SR.Coefficient sr, f (SR.SemiRingBase sr), SR.Coefficient sr)
asAffineVar w
  | [(WrapF r, c)] <- AM.toList (_sumMap w)
  = Just (c,r,_sumOffset w)

  | otherwise
  = Nothing

-- | Attempt to parse weighted sum as a single expression with a coefficient.
--   @asWeightedVar w = Just (c,r)@ when @denotation(w) = c*r@.
asWeightedVar :: WeightedSum f sr -> Maybe (SR.Coefficient sr, f (SR.SemiRingBase sr))
asWeightedVar w
  | [(WrapF r, c)] <- AM.toList (_sumMap w)
  , let sr = sumRepr w
  , SR.eq sr (SR.zero sr) (_sumOffset w)
  = Just (c,r)

  | otherwise
  = Nothing

-- | Attempt to parse a weighted sum as a single expression.
--   @asVar w = Just r@ when @denotation(w) = r@
asVar :: WeightedSum f sr -> Maybe (f (SR.SemiRingBase sr))
asVar w
  | [(WrapF r, c)] <- AM.toList (_sumMap w)
  , let sr = sumRepr w
  , SR.eq sr (SR.one sr) c
  , SR.eq sr (SR.zero sr) (_sumOffset w)
  = Just r

  | otherwise
  = Nothing

-- | Create a sum from a constant coefficient value.
constant :: Tm f => SR.SemiRingRepr sr -> SR.Coefficient sr -> WeightedSum f sr
constant sr c = unfilteredSum sr AM.empty c

-- | Traverse the expressions in a weighted sum.
traverseVars :: forall k j m sr.
  (Applicative m, Tm k) =>
  (j (SR.SemiRingBase sr) -> m (k (SR.SemiRingBase sr))) ->
  WeightedSum j sr ->
  m (WeightedSum k sr)
traverseVars f w =
  (\tms -> fromTerms sr tms (_sumOffset w)) <$>
  traverse (_1 f) (toListSumMap (_sumMap w))
  where sr = sumRepr w

-- | Traverse the coefficients in a weighted sum.
traverseCoeffs :: forall m f sr.
  (Applicative m, Tm f) =>
  (SR.Coefficient sr -> m (SR.Coefficient sr)) ->
  WeightedSum f sr ->
  m (WeightedSum f sr)
traverseCoeffs f w =
  unfilteredSum sr <$> AM.traverseMaybeWithKey g (_sumMap w) <*> f (_sumOffset w)
  where
    sr = sumRepr w
    g (WrapF t) _ c = mk t <$> f c
    mk t c = if SR.eq sr (SR.zero sr) c then Nothing else Just (mkNote sr c t, c)

-- | Traverse the expressions in a product.
traverseProdVars :: forall k j m sr.
  (Applicative m, Tm k) =>
  (j (SR.SemiRingBase sr) -> m (k (SR.SemiRingBase sr))) ->
  SemiRingProduct j sr ->
  m (SemiRingProduct k sr)
traverseProdVars f pd =
  mkProd sr . rebuild <$>
    traverse (_1 (traverseWrap f)) (AM.toList (_prodMap pd))
 where
  sr = prodRepr pd
  rebuild = foldl' (\m (WrapF t, occ) -> AM.insert (WrapF t) (mkProdNote sr occ t) occ m) AM.empty


-- | This returns a variable times a constant.
scaledVar :: Tm f => SR.SemiRingRepr sr -> SR.Coefficient sr -> f (SR.SemiRingBase sr) -> WeightedSum f sr
scaledVar sr s t
  | SR.eq sr (SR.zero sr) s = unfilteredSum sr AM.empty (SR.zero sr)
  | otherwise = unfilteredSum sr (singletonSumMap sr s t) (SR.zero sr)

-- | Create a weighted sum corresponding to the given variable.
var :: Tm f => SR.SemiRingRepr sr -> f (SR.SemiRingBase sr) -> WeightedSum f sr
var sr t = unfilteredSum sr (singletonSumMap sr (SR.one sr) t) (SR.zero sr)

-- | Add two sums, collecting terms as necessary and deleting terms whose
--   coefficients sum to 0.
add ::
  Tm f =>
  SR.SemiRingRepr sr ->
  WeightedSum f sr ->
  WeightedSum f sr ->
  WeightedSum f sr
add sr x y = unfilteredSum sr zm zc
  where
    merge (WrapF k) u v | SR.eq sr r (SR.zero sr) = Nothing
                        | otherwise               = Just (mkNote sr r k, r)
      where r = SR.add sr u v
    zm = AM.unionWithKeyMaybe merge (_sumMap x) (_sumMap y)
    zc = SR.add sr (x^.sumOffset) (y^.sumOffset)

-- | Create a weighted sum that represents the sum of two terms.
addVars ::
  Tm f =>
  SR.SemiRingRepr sr ->
  f (SR.SemiRingBase sr) ->
  f (SR.SemiRingBase sr) ->
  WeightedSum f sr
addVars sr x y = fromTerms sr [(x, SR.one sr), (y, SR.one sr)] (SR.zero sr)

-- | Add a variable to the sum.
addVar ::
  Tm f =>
  SR.SemiRingRepr sr ->
  WeightedSum f sr -> f (SR.SemiRingBase sr) -> WeightedSum f sr
addVar sr wsum x = wsum { _sumMap = m' }
  where m' = insertSumMap sr (SR.one sr) x (_sumMap wsum)

-- | Add a constant to the sum.
addConstant :: SR.SemiRingRepr sr -> WeightedSum f sr -> SR.Coefficient sr -> WeightedSum f sr
addConstant sr x r = x & sumOffset %~ SR.add sr r

-- | Multiply a sum by a constant coefficient.
scale :: Tm f => SR.SemiRingRepr sr -> SR.Coefficient sr -> WeightedSum f sr -> WeightedSum f sr
scale sr c wsum
  | SR.eq sr c (SR.zero sr) = constant sr (SR.zero sr)
  | otherwise = unfilteredSum sr m' (SR.mul sr c (wsum^.sumOffset))
  where
    m' = AM.mapMaybeWithKey f (wsum^.sumMap)
    f (WrapF t) _ x
      | SR.eq sr (SR.zero sr) cx = Nothing
      | otherwise = Just (mkNote sr cx t, cx)
      where cx = SR.mul sr c x

-- | Produce a weighted sum from a list of terms and an offset.
fromTerms ::
  Tm f =>
  SR.SemiRingRepr sr ->
  [(f (SR.SemiRingBase sr), SR.Coefficient sr)] ->
  SR.Coefficient sr ->
  WeightedSum f sr
fromTerms sr tms offset = unfilteredSum sr (fromListSumMap sr tms) offset

-- | Apply update functions to the terms and coefficients of a weighted sum.
transformSum :: (Applicative m, Tm g) =>
  SR.SemiRingRepr sr' ->
  (SR.Coefficient sr -> m (SR.Coefficient sr')) ->
  (f (SR.SemiRingBase sr) -> m (g (SR.SemiRingBase sr'))) ->
  WeightedSum f sr ->
  m (WeightedSum g sr')
transformSum sr' transCoef transTm s = fromTerms sr' <$> tms <*> c
  where
    f (t, x) = (,) <$> transTm t <*> transCoef x
    tms = traverse f (toListSumMap (_sumMap s))
    c   = transCoef (_sumOffset s)


-- | Evaluate a sum given interpretations of addition, scalar
-- multiplication, and a constant. This evaluation is threaded through
-- a monad. The addition function is associated to the left, as in
-- 'foldlM'.
evalM :: Monad m =>
  (r -> r -> m r) {- ^ Addition function -} ->
  (SR.Coefficient sr -> f (SR.SemiRingBase sr) -> m r) {- ^ Scalar multiply -} ->
  (SR.Coefficient sr -> m r) {- ^ Constant evaluation -} ->
  WeightedSum f sr ->
  m r
evalM addFn smul cnst sm
  | SR.eq sr (_sumOffset sm) (SR.zero sr) =
      case toListSumMap (_sumMap sm) of
        []             -> cnst (SR.zero sr)
        ((e, s) : tms) -> go tms =<< smul s e

  | otherwise =
      go (toListSumMap (_sumMap sm)) =<< cnst (_sumOffset sm)

  where
    sr = sumRepr sm

    go [] x = return x
    go ((e, s) : tms) x = go tms =<< addFn x =<< smul s e

-- | Evaluate a sum given interpretations of addition, scalar multiplication, and
-- a constant rational.
eval ::
  (r -> r -> r) {- ^ Addition function -} ->
  (SR.Coefficient sr -> f (SR.SemiRingBase sr) -> r) {- ^ Scalar multiply -} ->
  (SR.Coefficient sr -> r) {- ^ Constant evaluation -} ->
  WeightedSum f sr ->
  r
eval addFn smul cnst w
  | SR.eq sr (_sumOffset w) (SR.zero sr) =
      case toListSumMap (_sumMap w) of
        []             -> cnst (SR.zero sr)
        ((e, s) : tms) -> go tms (smul s e)

  | otherwise =
      go (toListSumMap (_sumMap w)) (cnst (_sumOffset w))

  where
    sr = sumRepr w

    go [] x = x
    go ((e, s) : tms) x = go tms (addFn (smul s e) x)

{-# INLINABLE eval #-}


-- | Reduce a weighted sum of integers modulo a concrete integer.
--   This reduces each of the coefficients modulo the given integer,
--   removing any that are congruent to 0; the offset value is
--   also reduced.
reduceIntSumMod ::
  Tm f =>
  WeightedSum f SR.SemiRingInteger {- ^ The sum to reduce -} ->
  Integer {- ^ The modulus, must not be 0 -} ->
  WeightedSum f SR.SemiRingInteger
reduceIntSumMod ws k = unfilteredSum SR.SemiRingIntegerRepr m (ws^.sumOffset `mod` k)
  where
    sr = sumRepr ws
    m = runIdentity (AM.traverseMaybeWithKey f (ws^.sumMap))
    f (WrapF t) _ x
      | x' == 0   = return Nothing
      | otherwise = return (Just (mkNote sr x' t, x'))
      where x' = x `mod` k

{-# INLINABLE extractCommon #-}

-- | Given two weighted sums @x@ and @y@, this returns a triple @(z,x',y')@
-- where @x = z + x'@ and @y = z + y'@ and @z@ contains the "common"
-- parts of @x@ and @y@.  We only extract common terms when both
-- terms occur with the same coefficient in each sum.
--
-- This is primarily used to simplify if-then-else expressions to
-- preserve shared subterms.
extractCommon ::
  Tm f =>
  WeightedSum f sr ->
  WeightedSum f sr ->
  (WeightedSum f sr, WeightedSum f sr, WeightedSum f sr)
extractCommon (WeightedSum xm xc sr) (WeightedSum ym yc _) = (z, x', y')
  where
    mergeCommon (WrapF t) (_, xv) (_, yv)
      | SR.eq sr xv yv  = Just (mkNote sr xv t, xv)
      | otherwise       = Nothing

    zm = AM.mergeWithKey mergeCommon (const AM.empty) (const AM.empty) xm ym

    (zc, xc', yc')
      | SR.eq sr xc yc = (xc, SR.zero sr, SR.zero sr)
      | otherwise      = (SR.zero sr, xc, yc)

    z = unfilteredSum sr zm zc

    x' = unfilteredSum sr (xm `AM.difference` zm) xc'
    y' = unfilteredSum sr (ym `AM.difference` zm) yc'


-- | Returns true if the product is trivial (contains no terms).
nullProd :: SemiRingProduct f sr -> Bool
nullProd pd = AM.null (_prodMap pd)

-- | If the product consists of exactly on term, return it.
asProdVar :: SemiRingProduct f sr -> Maybe (f (SR.SemiRingBase sr))
asProdVar pd
  | [(WrapF x, SR.occ_count sr -> 1)] <- AM.toList (_prodMap pd) = Just x
  | otherwise = Nothing
 where
 sr = prodRepr pd

prodAbsValue :: OrdF f => SemiRingProduct f sr -> AD.AbstractValue (SR.SemiRingBase sr)
prodAbsValue pd =
  fromSRAbsValue $
  case AM.annotation (_prodMap pd) of
    Nothing             -> abstractScalar (prodRepr pd) (SR.one (prodRepr pd))
    Just (ProdNote _ v) -> v

-- | Returns true if the product contains at least on occurrence of the given term.
prodContains :: OrdF f => SemiRingProduct f sr -> f (SR.SemiRingBase sr) -> Bool
prodContains pd x = isJust $ AM.lookup (WrapF x) (_prodMap pd)

-- | Produce a product map from a raw map of terms to occurrences.
--   PRECONDITION: the occurrence value for each term should be non-zero.
mkProd :: SR.SemiRingRepr sr -> ProdMap f sr -> SemiRingProduct f sr
mkProd sr m = SemiRingProduct m sr

-- | Produce a product representing the single given term.
prodVar :: Tm f => SR.SemiRingRepr sr -> f (SR.SemiRingBase sr) -> SemiRingProduct f sr
prodVar sr x = mkProd sr (singletonProdMap sr (SR.occ_one sr) x)

-- | Multiply two products, collecting terms and adding occurrences.
prodMul :: Tm f => SemiRingProduct f sr -> SemiRingProduct f sr -> SemiRingProduct f sr
prodMul x y = mkProd sr m
  where
  sr = prodRepr x
  mergeCommon (WrapF k) (_,a) (_,b) = Just (mkProdNote sr c k, c)
     where c = SR.occ_add sr a b
  m = AM.mergeWithKey mergeCommon id id (_prodMap x) (_prodMap y)

-- | Evaluate a product, given a function representing multiplication
--   and a function to evaluate terms.
prodEval ::
  (r -> r -> r) {-^ multiplication evalation -} ->
  (f (SR.SemiRingBase sr) -> r) {-^ term evaluation -} ->
  SemiRingProduct f sr ->
  Maybe r
prodEval mul tm om =
  runIdentity (prodEvalM (\x y -> Identity (mul x y)) (Identity . tm) om)

-- | Evaluate a product, given a function representing multiplication
--   and a function to evaluate terms, where both functions are threaded
--   through a monad.
prodEvalM :: Monad m =>
  (r -> r -> m r) {-^ multiplication evalation -} ->
  (f (SR.SemiRingBase sr) -> m r) {-^ term evaluation -} ->
  SemiRingProduct f sr ->
  m (Maybe r)
prodEvalM mul tm om = f (AM.toList (_prodMap om))
  where
  sr = prodRepr om

  -- we have not yet encountered a term with non-zero occurrences
  f [] = return Nothing
  f ((WrapF x, SR.occ_count sr -> n):xs)
    | n == 0    = f xs
    | otherwise =
        do t <- tm x
           t' <- go (n-1) t t
           g xs t'

  -- we have a partial product @z@ already computed and need to multiply
  -- in the remaining terms in the list
  g [] z = return (Just z)
  g ((WrapF x, SR.occ_count sr -> n):xs) z
    | n == 0    = g xs z
    | otherwise =
        do t <- tm x
           t' <- go n t z
           g xs t'

  -- compute: z * t^n
  go n t z
    | n > 0 = go (n-1) t =<< mul z t
    | otherwise = return z
