{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

{-
  This module shows how to use the registry with hedgehog generators
-}
module Test.Data.Registry.GenSpec where

import           Data.Registry
import           Hedgehog.Gen          as Gen
import           Hedgehog.Range        as Range
import           Protolude             as P
import           Test.Tasty.Extensions

-- * DATA MODEL

newtype Company =
  Company { departments :: [Department] }
  deriving (Eq, Show)

newtype Department =
  Department { employees :: [Employee] }
  deriving (Eq, Show)

data Employee = Employee {
    name   :: Name
  , age    :: Age
  , salary :: Salary
} deriving (Eq, Show)

newtype Name = Name Text deriving (Eq, Show)
newtype Age  = Age Int deriving (Eq, Show, Ord, Num)

data Salary =
    Fixed Int
  | Variable Int Double
  deriving (Eq, Show)

-- * GENERATORS

genText :: Gen Text
genText = Gen.text (Range.linear 2 10) Gen.ascii

genList :: forall a . (Typeable a) => Gen a -> Gen [a]
genList = Gen.list (Range.linear 0 3)

genInt :: Gen Int
genInt = Gen.int (Range.linear 1 100)

genDouble :: Gen Double
genDouble = Gen.double (Range.linearFrac 1 100)

setDepartmentWithOneEmployee :: Monad m => RegistryProperty m ()
setDepartmentWithOneEmployee = do
  e <- forall @Employee
  tweakGen @[Employee] (const $ pure [e])

setCompanyWithOneDepartment :: Monad m => RegistryProperty m ()
setCompanyWithOneDepartment = do
  d <- forall @Department
  tweakGen @[Department] (const (pure [d]))

setMinimalCompany :: Monad m => RegistryProperty m ()
setMinimalCompany =
  -- be careful, this is NOT commutative!
  -- if you set a company with one department first you may end up
  -- with a department with no employees, generated once and forall
  setDepartmentWithOneEmployee >>
  setCompanyWithOneDepartment

-- | Create a registry for all generators
registry =
     funTo @Gen Company
  +: funTo @Gen Department
  +: funTo @Gen Employee
  +: funTo @Gen Fixed
  +: funTo @Gen Name
  +: funTo @Gen Age
  +: fun (genList @Department)
  +: fun (genList @Employee)
  +: fun genInt
  +: fun genText
  +: fun genDouble
  +: end

test_company_with_one_employee = noShrink $ prop "generate just one employee" $ run $ do
  setMinimalCompany
  company <- forall @Company
  let allEmployees = company & departments >>= (& employees)
  length allEmployees === 1

-- * HELPERS

type RegistryProperty m a = forall ins out . StateT (Registry ins out) (PropertyT m) a

forall :: forall a m . (HasCallStack, Typeable a, Show a, Monad m) => RegistryProperty m a
forall = withFrozenCallStack $ get >>= P.lift . forAll . makeUnsafe @(Gen a)

tweakGen :: forall a m . (Typeable a, Monad m) => (Gen a -> Gen a) -> RegistryProperty m ()
tweakGen f = modify $ tweakUnsafe @(Gen a) f

run :: Monad m => RegistryProperty m a -> PropertyT m a
run = flip evalStateT registry
----
tests = $(testGroupGenerator)
