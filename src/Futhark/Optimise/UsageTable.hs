-- | A usage-table is sort of a bottom-up symbol table, describing how
-- (and if) a variable is used.
module Futhark.Optimise.UsageTable
  ( UsageTable
  , empty
  , contains
  , without
  , lookup
  , keys
  , used
  , isPredicate
  , isConsumed
  , usages
  , predicateUsage
  , consumedUsage
  , Usages
  )
  where

import Prelude hiding (lookup, any, foldl)

import Data.Foldable
import Data.Monoid
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import qualified Data.Set as S

import Futhark.InternalRep

newtype UsageTable = UsageTable (HM.HashMap VName Usages)
                   deriving (Eq, Show)

instance Monoid UsageTable where
  mempty = empty
  UsageTable table1 `mappend` UsageTable table2 =
    UsageTable $ HM.unionWith S.union table1 table2

empty :: UsageTable
empty = UsageTable HM.empty

contains :: UsageTable -> [VName] -> Bool
contains (UsageTable table) = any (`HM.member` table)

without :: UsageTable -> [VName] -> UsageTable
without (UsageTable table) = UsageTable . foldl (flip HM.delete) table

lookup :: VName -> UsageTable -> Maybe Usages
lookup name (UsageTable table) = HM.lookup name table

lookupPred :: (Usages -> Bool) -> VName -> UsageTable -> Bool
lookupPred f name = maybe False f . lookup name

used :: VName -> UsageTable -> Bool
used = lookupPred $ const True

keys :: UsageTable -> [VName]
keys (UsageTable table) = HM.keys table

isPredicate :: VName -> UsageTable -> Bool
isPredicate = lookupPred $ S.member Predicate

isConsumed :: VName -> UsageTable -> Bool
isConsumed = lookupPred $ S.member Consumed

usages :: HS.HashSet VName -> UsageTable
usages names = UsageTable $ HM.fromList [ (name, S.empty) | name <- HS.toList names ]

predicateUsage :: VName -> UsageTable
predicateUsage name = UsageTable $ HM.singleton name $ S.singleton Predicate

consumedUsage :: VName -> UsageTable
consumedUsage name = UsageTable $ HM.singleton name $ S.singleton Consumed

type Usages = S.Set Usage

data Usage = Predicate
           | Consumed
             deriving (Eq, Ord, Show)
