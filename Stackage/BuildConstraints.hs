{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
-- | The constraints on package selection for a new build plan.
module Stackage.BuildConstraints
    ( BuildConstraints (..)
    , PackageConstraints (..)
    , TestState (..)
    , SystemInfo (..)
    , getSystemInfo
    , defaultBuildConstraints
    , toBC
    , BuildConstraintsSource (..)
    , loadBuildConstraints
    ) where

import           Control.Monad.Writer.Strict (execWriter, tell)
import           Data.Aeson
import qualified Data.Map                    as Map
import           Data.Yaml                   (decodeEither', decodeFileEither)
import           Distribution.Package        (Dependency (..))
import           Distribution.System         (Arch, OS)
import qualified Distribution.System
import           Distribution.Version        (anyVersion)
import           Filesystem                  (isFile)
import           Network.HTTP.Client         (Manager, httpLbs, responseBody, Request)
import           Stackage.CorePackages
import           Stackage.Prelude

data TestState = ExpectSuccess
               | ExpectFailure
               | Don'tBuild -- ^ when the test suite will pull in things we don't want
    deriving (Show, Eq, Ord, Bounded, Enum)

testStateToText :: TestState -> Text
testStateToText ExpectSuccess = "expect-success"
testStateToText ExpectFailure = "expect-failure"
testStateToText Don'tBuild    = "do-not-build"

instance ToJSON TestState where
    toJSON = toJSON . testStateToText
instance FromJSON TestState where
    parseJSON = withText "TestState" $ \t ->
        case lookup t states of
            Nothing -> fail $ "Invalid state: " ++ unpack t
            Just v -> return v
      where
        states = asHashMap $ mapFromList
               $ map (\x -> (testStateToText x, x)) [minBound..maxBound]

data SystemInfo = SystemInfo
    { siGhcVersion      :: Version
    , siOS              :: OS
    , siArch            :: Arch
    , siCorePackages    :: Map PackageName Version
    , siCoreExecutables :: Set ExeName
    }
    deriving (Show, Eq, Ord)
instance ToJSON SystemInfo where
    toJSON SystemInfo {..} = object
        [ "ghc-version" .= display siGhcVersion
        , "os" .= display siOS
        , "arch" .= display siArch
        , "core-packages" .= Map.mapKeysWith const unPackageName (map display siCorePackages)
        , "core-executables" .= siCoreExecutables
        ]
instance FromJSON SystemInfo where
    parseJSON = withObject "SystemInfo" $ \o -> do
        let helper name = (o .: name) >>= either (fail . show) return . simpleParse
        siGhcVersion <- helper "ghc-version"
        siOS <- helper "os"
        siArch <- helper "arch"
        siCorePackages <- (o .: "core-packages") >>= goPackages
        siCoreExecutables <- o .: "core-executables"
        return SystemInfo {..}
      where
        goPackages = either (fail . show) return
                   . mapM simpleParse
                   . Map.mapKeysWith const mkPackageName

data BuildConstraints = BuildConstraints
    { bcPackages           :: Set PackageName
    -- ^ This does not include core packages.
    , bcPackageConstraints :: PackageName -> PackageConstraints

    , bcSystemInfo         :: SystemInfo

    , bcGithubUsers        :: Map Text (Set Text)
    -- ^ map an account to set of pingees
    }

data PackageConstraints = PackageConstraints
    { pcVersionRange     :: VersionRange
    , pcMaintainer       :: Maybe Maintainer
    , pcTests            :: TestState
    , pcHaddocks         :: TestState
    , pcBuildBenchmarks  :: Bool
    , pcFlagOverrides    :: Map FlagName Bool
    , pcEnableLibProfile :: Bool
    }
    deriving (Show, Eq)
instance ToJSON PackageConstraints where
    toJSON PackageConstraints {..} = object $ addMaintainer
        [ "version-range" .= display pcVersionRange
        , "tests" .= pcTests
        , "haddocks" .= pcHaddocks
        , "build-benchmarks" .= pcBuildBenchmarks
        , "flags" .= Map.mapKeysWith const unFlagName pcFlagOverrides
        , "library-profiling" .= pcEnableLibProfile
        ]
      where
        addMaintainer = maybe id (\m -> (("maintainer" .= m):)) pcMaintainer
instance FromJSON PackageConstraints where
    parseJSON = withObject "PackageConstraints" $ \o -> do
        pcVersionRange <- (o .: "version-range")
                      >>= either (fail . show) return . simpleParse
        pcTests <- o .: "tests"
        pcHaddocks <- o .: "haddocks"
        pcBuildBenchmarks <- o .: "build-benchmarks"
        pcFlagOverrides <- Map.mapKeysWith const mkFlagName <$> o .: "flags"
        pcMaintainer <- o .:? "maintainer"
        pcEnableLibProfile <- fmap (fromMaybe False) (o .:? "library-profiling")
        return PackageConstraints {..}

-- | The proposed plan from the requirements provided by contributors.
--
-- Checks the current directory for a build-constraints.yaml file and uses it
-- if present. If not, downloads from Github.
defaultBuildConstraints :: Manager -> IO BuildConstraints
defaultBuildConstraints = loadBuildConstraints BCSDefault

data BuildConstraintsSource
    = BCSDefault
    | BCSFile FilePath
    | BCSWeb Request
    deriving (Show)

loadBuildConstraints :: BuildConstraintsSource -> Manager -> IO BuildConstraints
loadBuildConstraints bcs man = do
    case bcs of
        BCSDefault -> do
            e <- isFile fp0
            if e
                then loadFile fp0
                else loadReq req0
        BCSFile fp -> loadFile fp
        BCSWeb req -> loadReq req
  where
    fp0 = "build-constraints.yaml"
    req0 = "https://raw.githubusercontent.com/fpco/stackage/master/build-constraints.yaml"

    loadFile fp = decodeFileEither (fpToString fp) >>= either throwIO toBC
    loadReq req = httpLbs req man >>=
                  either throwIO toBC . decodeEither' . toStrict . responseBody


getSystemInfo :: IO SystemInfo
getSystemInfo = do
    siCorePackages <- getCorePackages
    siCoreExecutables <- getCoreExecutables
    siGhcVersion <- getGhcVersion
    return SystemInfo {..}
  where
    -- FIXME consider not hard-coding the next two values
    siOS   = Distribution.System.Linux
    siArch = Distribution.System.X86_64

data ConstraintFile = ConstraintFile
    { cfPackageFlags            :: Map PackageName (Map FlagName Bool)
    , cfSkippedTests            :: Set PackageName
    , cfExpectedTestFailures    :: Set PackageName
    , cfExpectedHaddockFailures :: Set PackageName
    , cfSkippedBenchmarks       :: Set PackageName
    , cfPackages                :: Map Maintainer (Vector Dependency)
    , cfGithubUsers             :: Map Text (Set Text)
    , cfSkippedLibProfiling     :: Set PackageName
    }

instance FromJSON ConstraintFile where
    parseJSON = withObject "ConstraintFile" $ \o -> do
        cfPackageFlags <- (goPackageMap . fmap goFlagMap) <$> o .: "package-flags"
        cfSkippedTests <- getPackages o "skipped-tests"
        cfExpectedTestFailures <- getPackages o "expected-test-failures"
        cfExpectedHaddockFailures <- getPackages o "expected-haddock-failures"
        cfSkippedBenchmarks <- getPackages o "skipped-benchmarks"
        cfSkippedLibProfiling <- getPackages o "skipped-profiling"
        cfPackages <- o .: "packages"
                  >>= mapM (mapM toDep)
                    . Map.mapKeysWith const Maintainer
        cfGithubUsers <- o .: "github-users"
        return ConstraintFile {..}
      where
        goFlagMap = Map.mapKeysWith const FlagName
        goPackageMap = Map.mapKeysWith const PackageName
        getPackages o name = (setFromList . map PackageName) <$> o .: name

        toDep :: Monad m => Text -> m Dependency
        toDep = either (fail . show) return . simpleParse

toBC :: ConstraintFile -> IO BuildConstraints
toBC ConstraintFile {..} = do
    bcSystemInfo <- getSystemInfo
    return BuildConstraints {..}
  where
    combine (maintainer, range1) (_, range2) =
        (maintainer, intersectVersionRanges range1 range2)
    revmap = unionsWith combine $ ($ []) $ execWriter
           $ forM_ (mapToList cfPackages)
           $ \(maintainer, deps) -> forM_ deps
           $ \(Dependency name range) ->
            tell (singletonMap name (maintainer, range):)

    bcPackages = Map.keysSet revmap

    bcPackageConstraints name =
        PackageConstraints {..}
      where
        mpair = lookup name revmap
        pcMaintainer = fmap fst mpair
        pcVersionRange = maybe anyVersion snd mpair
        pcEnableLibProfile = not (name `member` cfSkippedLibProfiling)
        pcTests
            | name `member` cfSkippedTests = Don'tBuild
            | name `member` cfExpectedTestFailures = ExpectFailure
            | otherwise = ExpectSuccess
        pcBuildBenchmarks = name `notMember` cfSkippedBenchmarks
        pcHaddocks
            | name `member` cfExpectedHaddockFailures = ExpectFailure

            | otherwise = ExpectSuccess
        pcFlagOverrides = fromMaybe mempty $ lookup name cfPackageFlags

    bcGithubUsers = cfGithubUsers
