module Spago.Search.Index where

import Prelude

import Spago.Search.DocsJson (ChildDeclType(..), ChildIndexEntry(..), DataDeclType, DeclType(..), Declarations(..), IndexEntry(..))
import Spago.Search.TypeDecoder (Constraint(..), FunDeps, Kind, QualifiedName(..), Type(..), TypeArgument)
import Spago.Search.TypeShape (ShapeChunk, joinForAlls, shapeOfType)

import Control.Alt ((<|>))
import Data.Array ((!!))
import Data.Foldable (foldr)
import Data.List (List, (:))
import Data.List as List
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Search.Trie (Trie, alter, entriesUnordered)
import Data.String.CodeUnits (stripPrefix, stripSuffix, toCharArray)
import Data.String.Common (toLower)
import Data.String.Common as String
import Data.String.Pattern (Pattern(..))
import Data.Tuple (Tuple(..))

newtype SearchIndex
  = SearchIndex  { decls :: Trie Char (List SearchResult)
                 , types :: Trie ShapeChunk (List SearchResult)
                 }

derive instance newtypeSearchIndex :: Newtype SearchIndex _

data ResultInfo
  = DataResult            { typeArguments :: Array TypeArgument
                          , dataDeclType :: DataDeclType }
  | ExternDataResult      { kind :: Kind }
  | TypeSynonymResult     { arguments :: Array TypeArgument
                          , type :: Type }
  | DataConstructorResult { arguments :: Array Type }
  | TypeClassMemberResult { type :: Type
                          , typeClass :: QualifiedName
                          , typeClassArguments :: Array String }
  | TypeClassResult       { fundeps :: FunDeps
                          , arguments :: Array TypeArgument
                          , superclasses :: Array Constraint }
  | ValueResult           { type :: Type }
  | ValueAliasResult
  | TypeAliasResult
  | ExternKindResult

newtype SearchResult
  = SearchResult { name :: String
                 , comments :: Maybe String
                 , hashAnchor :: String
                 , moduleName :: String
                 , packageName :: String
                 , sourceSpan :: Maybe { start :: Array Int
                                       , end :: Array Int
                                       , name :: String
                                       }
                 , info :: ResultInfo
                 }

derive instance newtypeSearchResult :: Newtype SearchResult _

mkSearchIndex :: Array Declarations -> SearchIndex
mkSearchIndex decls =
  SearchIndex { decls: trie
              , types
              }
  where
    trie = foldr insertDeclarations mempty decls
    types = foldr insertTypes mempty do
      Tuple _ results <- entriesUnordered trie
      result <- results
      case (unwrap result).info of
        ValueResult dict ->
          insertTypeResultsFor dict.type result
        TypeClassMemberResult dict ->
          -- TODO: fix missing foralls for type class members
          insertTypeResultsFor dict.type result

        TypeSynonymResult dict ->
          insertTypeResultsFor dict.type result
        _ -> mempty

    insertTypeResultsFor ty result =
      let path = shapeOfType ty in
      pure $ Tuple path result

insertTypes
  :: Tuple (List ShapeChunk) SearchResult
  -> Trie ShapeChunk (List SearchResult)
  -> Trie ShapeChunk (List SearchResult)
insertTypes (Tuple path result) trie =
  alter path updateResults trie
  where
    updateResults mbOldResults =
      case mbOldResults of
        Just oldResults ->
          Just $ result : oldResults
        Nothing ->
          Just $ List.singleton result

insertDeclarations
  :: Declarations
  -> Trie Char (List SearchResult)
  -> Trie Char (List SearchResult)
insertDeclarations (Declarations { name, declarations }) trie
  = foldr (insertIndexEntry name) trie declarations

insertIndexEntry
  :: String
  -> IndexEntry
  -> Trie Char (List SearchResult)
  -> Trie Char (List SearchResult)
insertIndexEntry moduleName entry@(IndexEntry { title }) trie
  = foldr insertSearchResult trie (resultsForEntry moduleName entry)

insertSearchResult
  :: { path :: String
     , result :: SearchResult
     }
  -> Trie Char (List SearchResult)
  -> Trie Char (List SearchResult)
insertSearchResult { path, result } trie =
  let path' = List.fromFoldable $ toCharArray $ toLower path in
    alter path' updateResults trie
    where
      updateResults mbOldResults =
        case mbOldResults of
          Just oldResults ->
            Just $ result : oldResults
          Nothing ->
            Just $ List.singleton result

resultsForEntry
  :: String
  -> IndexEntry
  -> List { path :: String
          , result :: SearchResult
          }
resultsForEntry moduleName indexEntry@(IndexEntry entry) =
  let { info, title, sourceSpan, comments, children } = entry
      { name, declLevel } = getLevelAndName info.declType title
      packageName = extractPackageName sourceSpan.name
  in case mkInfo declLevel indexEntry of
       Nothing -> mempty
       Just info' ->
         let result = SearchResult { name: title
                                   , comments
                                   , hashAnchor: declLevelToHashAnchor declLevel
                                   , moduleName
                                   , sourceSpan: Just sourceSpan
                                   , packageName
                                   , info: info'
                                   }
         in
           ( List.singleton $
               { path: name
               , result
               }
           ) <>
           ( List.fromFoldable children >>=
             resultsForChildIndexEntry packageName moduleName result
           )

mkInfo :: DeclLevel -> IndexEntry -> Maybe ResultInfo
mkInfo declLevel (IndexEntry { info, title }) =
  case info.declType of

    DeclValue ->
      info.type <#>
      \ty -> ValueResult { type: ty }

    DeclData ->
       make <$> info.typeArguments <*> info.dataDeclType
        where
          make typeArguments dataDeclType =
            DataResult { typeArguments, dataDeclType }

    DeclExternData ->
      info.kind <#>
      \kind -> ExternDataResult { kind }

    DeclTypeSynonym ->
      make <$> info.type <*> info.arguments
        where
          make ty args = TypeSynonymResult { type: ty, arguments: args }

    DeclTypeClass ->
      case info.fundeps, info.arguments, info.superclasses of
        Just fundeps, Just arguments, Just superclasses ->
          Just $ TypeClassResult { fundeps, arguments, superclasses }
        _, _, _ -> Nothing

    DeclAlias ->
      case declLevel of
        TypeLevel  -> Just TypeAliasResult
        ValueLevel -> Just ValueAliasResult
        _          -> Nothing

    DeclExternKind ->
      Just ExternKindResult

-- | Level of a declaration, used to determine which URI hash anchor to use in
-- | links ("v", "t" or "k").
data DeclLevel = ValueLevel | TypeLevel | KindLevel

declLevelToHashAnchor :: DeclLevel -> String
declLevelToHashAnchor = case _ of
  ValueLevel -> "v"
  TypeLevel  -> "t"
  KindLevel  -> "k"

getLevelAndName
  :: DeclType
  -> String
  -> { declLevel :: DeclLevel
     , name :: String
     }
getLevelAndName DeclValue       name = { name, declLevel: ValueLevel }
getLevelAndName DeclData        name = { name, declLevel: TypeLevel }
getLevelAndName DeclTypeSynonym name = { name, declLevel: TypeLevel }
getLevelAndName DeclTypeClass   name = { name, declLevel: ValueLevel }
-- "declType": "alias" does not specify the level of the declaration.
-- But for type aliases, name of the declaration is always wrapped into
-- "type (" and ")".
getLevelAndName DeclAlias       title =
  fromMaybe (withAnchor ValueLevel title) $
  (withAnchor ValueLevel <$>
   (stripPrefix (Pattern "(") >=>
    stripSuffix (Pattern ")")) title) <|>
  (withAnchor TypeLevel <$>
    (stripPrefix (Pattern "type (") >=>
     stripSuffix (Pattern ")")) title)
  where
    withAnchor declLevel name = { declLevel, name }
getLevelAndName DeclExternData  name = { name, declLevel: TypeLevel }
getLevelAndName DeclExternKind  name = { name, declLevel: KindLevel }

-- | Extract package name from `sourceSpan.name`, which contains path to
-- | the source file.
extractPackageName :: String -> String
extractPackageName name =
  let chunks = String.split (Pattern "/") name in
  fromMaybe "<unknown>" $
  chunks !! 0 >>= \dir ->
  -- TODO: is it safe to assume that directory name is ".spago"?
  if dir == ".spago" then
    chunks !! 1
  else
    Just "<local package>"

resultsForChildIndexEntry
  :: String
  -> String
  -> SearchResult
  -> ChildIndexEntry
  -> List { path :: String, result :: SearchResult }
resultsForChildIndexEntry packageName moduleName parentResult
  child@(ChildIndexEntry { title, info, comments, mbSourceSpan }) =
    case mkChildInfo parentResult child of
      Nothing -> mempty
      Just resultInfo ->
        { path: title
        , result: SearchResult { name: title
                               , comments
                               , hashAnchor: "v"
                               , moduleName
                               , sourceSpan: mbSourceSpan
                               , packageName
                               , info: resultInfo
                               }
        } # List.singleton

mkChildInfo :: SearchResult -> ChildIndexEntry -> Maybe ResultInfo
mkChildInfo parentResult (ChildIndexEntry { info } ) =
  case info.declType of
    ChildDeclDataConstructor ->
      info.arguments <#>
      \arguments -> DataConstructorResult { arguments }
    ChildDeclTypeClassMember ->
      case (unwrap parentResult).info of
        TypeClassResult { arguments } ->
          -- We need to reconstruct a "real" type of a type class member.
          -- For example, if `unconstrainedType` is the type of `pure`, i.e. `forall a. a -> m a`,
          -- `restoredType` should be `forall m a. Control.Applicative.Applicative m => a -> m a`.
          info.type <#>
            \(unconstrainedType :: Type) ->
            let
              -- First, we get a list of nested `forall` quantifiers for `unconstrainedType`
              -- and a version of `unconstrainedType` without them (`ty`).
              { ty, binders } = joinForAlls unconstrainedType

              -- Then we construct a qualified name of the type class.
              parentClassName =
                QualifiedName { moduleName: String.split (wrap ".") (unwrap parentResult).moduleName
                              , name: (unwrap parentResult).name }

              typeClassArguments = arguments <#> unwrap >>> _.name

              -- We concatenate two lists:
              -- * list of type parameters of the type class, and
              -- * list of quantified variables of the unconstrained type
              allArguments =
                typeClassArguments <> (List.toUnfoldable binders <#> (_.var))

              restoredType =
                foldr (\arg -> compose (\type'' -> ForAll arg type'' Nothing)) identity allArguments $
                ConstrainedType (Constraint { constraintClass: parentClassName
                                            , constraintArgs: typeClassArguments <#> TypeVar
                                            }) ty

            in TypeClassMemberResult
               { type: restoredType
               , typeClass: parentClassName
               , typeClassArguments
               }
        _ -> Nothing
    ChildDeclInstance -> Nothing
