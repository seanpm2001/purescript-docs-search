module Docs.Search.Engine where

import Docs.Search.ModuleIndex (ModuleIndex, ModuleResult)
import Docs.Search.PackageIndex (PackageIndex, PackageResult)
import Docs.Search.Score (Scores)
import Docs.Search.SearchResult (SearchResult, typeOfResult)
import Docs.Search.TypeQuery (TypeQuery(..), parseTypeQuery, penalty)
import Docs.Search.Types (PackageName, ModuleName)

import Prelude

import Data.Array as Array
import Data.Either (hush)
import Data.Function (on)
import Data.List (List)
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Data.Search.Trie (Trie)
import Data.String.Common (toLower) as String


type Index = Trie Char (List SearchResult)


type Query m index input result =
  index -> input -> m { index :: index, results :: Array result }


type Engine m index typeIndex =
  { queryIndex
    :: Query m index String SearchResult
  , queryTypeIndex
    :: Query m typeIndex TypeQuery SearchResult
  , queryPackageIndex
    :: Query m PackageIndex String PackageResult
  , queryModuleIndex
    :: Scores -> ModuleIndex -> String -> Array ModuleResult
  }


type EngineState index typeIndex
  = { index :: index
    , typeIndex :: typeIndex
    , packageIndex :: PackageIndex
    , moduleIndex :: ModuleIndex
    , scores :: Scores
    }


mkEngineState
  :: forall index typeIndex
  .  index
  -> typeIndex
  -> PackageIndex
  -> ModuleIndex
  -> Scores
  -> EngineState index typeIndex
mkEngineState index typeIndex packageIndex moduleIndex scores =
  { index, typeIndex, packageIndex, moduleIndex, scores }


data Result
  = DeclResult SearchResult
  | TypeResult SearchResult
  | PackResult PackageResult
  | MdlResult  ModuleResult


getResultScore :: Result -> Int
getResultScore (DeclResult r) = (unwrap r).score
getResultScore (TypeResult r) = (unwrap r).score
getResultScore (PackResult r) = r.score
getResultScore (MdlResult r) = r.score


getResultPackageName :: Result -> PackageName
getResultPackageName (DeclResult r) = (unwrap r).packageName
getResultPackageName (TypeResult r) = (unwrap r).packageName
getResultPackageName (PackResult r) = r.name
getResultPackageName (MdlResult r) = r.package


getResultModuleName :: Result -> ModuleName
getResultModuleName (DeclResult r) = (unwrap r).moduleName
getResultModuleName (TypeResult r) = (unwrap r).moduleName
getResultModuleName (PackResult r) = ""
getResultModuleName (MdlResult r) = r.name


sortByPopularity
  :: forall index typeIndex
  .  EngineState index typeIndex
  -> Array Result
  -> Array Result
sortByPopularity { packageIndex } =
  Array.sortBy (
    compare `on` (getResultScore >>> negate) <>
    compare `on` getResultPackageName <>
    compare `on` getResultModuleName
  )


query
  :: forall m index typeIndex
  .  Monad m
  => Engine m index typeIndex
  -> Query m (EngineState index typeIndex) String Result
query engine state input =
  case hush (parseTypeQuery input) >>= isValuableTypeQuery of

    -- A declaration/package query
    Nothing -> do
      let lowerCased = String.toLower input

      response        <- engine.queryIndex         state.index        lowerCased
      packageResponse <- engine.queryPackageIndex  state.packageIndex lowerCased
      let moduleResponse =
            engine.queryModuleIndex state.scores state.moduleIndex lowerCased

      pure { results: sortByPopularity state $
             (packageResponse.results <#> PackResult) <>
             (moduleResponse          <#> MdlResult) <>
             (response.results        <#> DeclResult)

             -- No need to update package index (it never changes).
           , index: state { index = response.index }
           }

    -- A type query
    Just typeQuery -> do

      response <- engine.queryTypeIndex state.typeIndex typeQuery

      pure { results: sortByDistance typeQuery (response.results) <#> TypeResult
           , index: state { typeIndex = response.index }
           }


isValuableTypeQuery :: TypeQuery -> Maybe TypeQuery
isValuableTypeQuery (QVar _) = Nothing
isValuableTypeQuery (QConst _) = Nothing
isValuableTypeQuery other = Just other


sortByDistance
  :: TypeQuery
  -> Array SearchResult
  -> Array SearchResult
sortByDistance typeQuery =
  Array.sortWith (map (penalty typeQuery) <<< typeOfResult)
