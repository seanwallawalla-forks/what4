------------------------------------------------------------------------
-- |
-- Module      : What4.ProblemFeatures
-- Description : Descriptions of the "features" that can occur in queries
-- Copyright   : (c) Galois, Inc 2016-2020
-- License     : BSD3
-- Maintainer  : Joe Hendrix <jhendrix@galois.com>
-- Stability   : provisional
--
-- ProblemFeatures uses bit mask to represent the features.  The bits are:
--
--  0 : Uses linear arithmetic
--  1 : Uses non-linear arithmetic, i.e. multiplication (should also set bit 0)
--  2 : Uses computational reals (should also set bits 0 & 1)
--  3 : Uses integer variables (should also set bit 0)
--  4 : Uses bitvectors
--  5 : Uses exists-forall.
--  6 : Uses quantifiers (should also set bit 5)
--  7 : Uses symbolic arrays or complex numbers.
--  8 : Uses structs
--  9 : Uses strings
-- 10 : Uses floating-point
-- 11 : Computes UNSAT cores
-- 12 : Computes UNSAT assumptions
-- 13 : Uses uninterpreted functions
-- 14 : Uses defined functions
------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module What4.ProblemFeatures
  ( ProblemFeatures
  , noFeatures
  , useLinearArithmetic
  , useNonlinearArithmetic
  , useComputableReals
  , useIntegerArithmetic
  , useBitvectors
  , useExistForall
  , useQuantifiers
  , useSymbolicArrays
  , useStructs
  , useStrings
  , useFloatingPoint
  , useUnsatCores
  , useUnsatAssumptions
  , useUninterpFunctions
  , useDefinedFunctions
  , hasProblemFeature
  ) where

import Data.Bits
import Data.Word

-- | Allowed features represents features that the constraint solver
-- will need to support to solve the problem.
newtype ProblemFeatures = ProblemFeatures Word64
  deriving (Eq, Bits)

noFeatures :: ProblemFeatures
noFeatures = ProblemFeatures 0

-- | Indicates whether the problem uses linear arithmetic.
useLinearArithmetic :: ProblemFeatures
useLinearArithmetic = ProblemFeatures 0x01

-- | Indicates whether the problem uses non-linear arithmetic.
useNonlinearArithmetic :: ProblemFeatures
useNonlinearArithmetic = ProblemFeatures 0x03

-- | Indicates whether the problem uses computable real functions.
useComputableReals :: ProblemFeatures
useComputableReals = ProblemFeatures 0x04 .|. useNonlinearArithmetic

-- | Indicates the problem contains integer variables.
useIntegerArithmetic :: ProblemFeatures
useIntegerArithmetic = ProblemFeatures 0x08 .|. useLinearArithmetic

-- | Indicates whether the problem uses bitvectors.
useBitvectors :: ProblemFeatures
useBitvectors = ProblemFeatures 0x10

-- | Indicates whether the problem needs exists-forall support.
useExistForall :: ProblemFeatures
useExistForall = ProblemFeatures 0x20

-- | Has general quantifier support.
useQuantifiers :: ProblemFeatures
useQuantifiers = ProblemFeatures 0x40 .|. useExistForall

-- | Indicates whether the problem uses symbolic arrays.
useSymbolicArrays :: ProblemFeatures
useSymbolicArrays = ProblemFeatures 0x80

-- | Indicates whether the problem uses structs
--
-- Structs are modeled using constructors in CVC4/Z3, and tuples
-- in Yices.
useStructs :: ProblemFeatures
useStructs = ProblemFeatures 0x100

-- | Indicates whether the problem uses strings
--
--   Strings have some symbolic support in CVC4 and Z3.
useStrings :: ProblemFeatures
useStrings = ProblemFeatures 0x200

-- | Indicates whether the problem uses floating-point
--
--   Floating-point has some symbolic support in CVC4 and Z3.
useFloatingPoint :: ProblemFeatures
useFloatingPoint = ProblemFeatures 0x400

-- | Indicates if the solver is able and configured to compute UNSAT
--   cores.
useUnsatCores :: ProblemFeatures
useUnsatCores = ProblemFeatures 0x800

-- | Indicates if the solver is able and configured to compute UNSAT
--   assumptions.
useUnsatAssumptions :: ProblemFeatures
useUnsatAssumptions = ProblemFeatures 0x1000

-- | Indicates if the solver is able and configured to use
--   uninterpreted functions.
useUninterpFunctions :: ProblemFeatures
useUninterpFunctions = ProblemFeatures 0x2000

-- | Indicates if the solver is able and configured to use
--   defined functions.
useDefinedFunctions :: ProblemFeatures
useDefinedFunctions = ProblemFeatures 0x4000

-- | Tests if one set of problem features subsumes another.
--   In particular, @hasProblemFeature x y@ is true iff
--   the set of features in @x@ is a superset of those in @y@.
hasProblemFeature :: ProblemFeatures -> ProblemFeatures -> Bool
hasProblemFeature x y = (x .&. y) == y
