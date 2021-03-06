{-# LANGUAGE OverloadedStrings #-}

module Lib.RouteUtilsSpecs where

import           Test.Hspec     (Spec, describe, it, pending, shouldBe)

-- global modules tests rely on
import           Data.Default   (def)

-- local modules to set up tests
import           Types.Errors   (SiteGenError (..))
import           Types.Header   (SourceMetadata (..))

-- module under test
import qualified Lib.RouteUtils as RU


checkDuplicateRoutesSpecs :: Spec
checkDuplicateRoutesSpecs = --do

    describe "checkDuplicateRoutesSpecs" $ do

        it "Should do nothing with an empty list" $
            RU.checkDuplicateRoutes [] `shouldBe` []

        it "Should provide an empty list with no duplicates" $
            RU.checkDuplicateRoutes [s1, s2, s3] `shouldBe` []

        it "Should indicate the duplicate with 2 errors" $
            RU.checkDuplicateRoutes [s1, s2, d1, s3] `shouldBe` [e1,e2]



s1 :: SourceMetadata
s1 = def {smRoute="r1", smRelFilePath=Just "f1"}


s2 :: SourceMetadata
s2 = def {smRoute="r2", smRelFilePath=Just "f2"}


s3 :: SourceMetadata
s3 = def {smRoute="r3", smRelFilePath=Just "f3"}


d1 :: SourceMetadata
d1 = def {smRoute="r1", smRelFilePath=Just "d1"}


-- errors
e1 = RU.DuplicateRouteError s1 "Pages share same route: \"r1\", filenames: f1, d1"
e2 = RU.DuplicateRouteError d1 "Pages share same route: \"r1\", filenames: f1, d1"
