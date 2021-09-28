{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}

module Servant.PureScript.CodeGen where

import           Control.Lens                       hiding (List)
import qualified Data.Map                           as Map
import           Data.Maybe                         (mapMaybe, maybeToList)
import qualified Data.Set                           as Set
import           Data.Text                          (Text)
import qualified Data.Text.Encoding                 as T
import           Language.PureScript.Bridge
import           Language.PureScript.Bridge.PSTypes (psString)
import           Network.HTTP.Types.URI             (urlEncode)
import           Servant.Foreign
import           Servant.PureScript.Internal
import           Text.PrettyPrint.Mainland

genModule :: Settings -> [Req PSType] -> Doc
genModule opts reqs = let
    allParams  = concatMap reqToParams reqs
    rParams    = getReaderParams opts allParams
    apiImports = reqsToImportLines reqs
    imports    = mergeImportLines (_standardImports opts) apiImports
  in
    genModuleHeader (_apiModuleName opts) imports
    </> genParamSettings rParams <> line
    </> (docIntercalate line . map (genFunction rParams)) reqs

genModuleHeader :: Text -> ImportLines -> Doc
genModuleHeader moduleName imports = let
    importLines = map (strictText . importLineToText) . Map.elems $ imports
  in
        "-- File auto generated by servant-purescript! --"
    </> "module" <+> strictText moduleName <+> "where" <> line
    </> "import Prelude" <> line
    </> docIntercalate line importLines <> line

getReaderParams :: Settings -> [PSParam] -> [PSParam]
getReaderParams opts allParams = let
    isReaderParam      = (`Set.member` _readerParams opts) . _pName
    rParamsDirty       = filter isReaderParam allParams
    rParamsMap         = Map.fromListWith useOld . map toPair $ rParamsDirty
    rParams            = map fromPair . Map.toList $ rParamsMap
    -- Helpers
    toPair (Param n t) = (n, t)
    fromPair (n, t) = Param n t
    useOld            = flip const
  in
    rParams

genParamSettings :: [PSParam]-> Doc
genParamSettings rParams = let
    genEntry arg = arg ^. (pName . to psVar) <+> "::" <+> arg ^. (pType . typeName . to strictText)
    genEntries   = docIntercalate (line <> ", ") . map genEntry
  in
    "newtype SPParams_ = SPParams_" <+/> align (
              lbrace
          <+> genEntries rParams
          </> rbrace
          )
    </>
    "derive instance newtypeSPParams_ :: Newtype SPParams_ _"

genFunction :: [PSParam] -> Req PSType -> Doc
genFunction allRParams req = let
    rParamsSet = Set.fromList allRParams
    fnName = req ^. reqFuncName ^. jsCamelCaseL
    allParamsList = baseURLParam : reqToParams req
    allParams = Set.fromList allParamsList
    fnParams = filter (not . flip Set.member rParamsSet) allParamsList -- Use list not set, as we don't want to change order of parameters
    rParams = Set.toList $ rParamsSet `Set.intersection` allParams

    pTypes = map _pType fnParams
    pNames = map _pName fnParams
    signature = genSignature fnName pTypes (req ^. reqReturnType)
    body = genFnHead fnName pNames <+> genFnBody rParams req
  in signature </> body


genGetReaderParams :: [PSParam] -> Doc
genGetReaderParams = stack . map (genGetReaderParam . psVar . _pName)
  where
    genGetReaderParam pName' = "let" <+> pName' <+> "= spParams_." <> pName'


genSignature :: Text -> [PSType] -> Maybe PSType -> Doc
genSignature = genSignatureBuilder $ "forall m." <+/> "MonadAsk (SPSettings_ SPParams_) m => MonadError AjaxError m => MonadAff m" <+/> "=>"

genSignatureBuilder :: Doc -> Text -> [PSType] -> Maybe PSType -> Doc
genSignatureBuilder constraint fnName params mRet = fName <+> "::" <+> align (constraint <+/> parameterString)
  where
    fName = strictText fnName
    retName = maybe "Unit" (strictText . typeInfoToText False) mRet
    retString = "m" <+> retName
    typeNames = map (strictText . typeInfoToText True) params
    parameterString = docIntercalate (softline <> "-> ") (typeNames <> [retString])

genFnHead :: Text -> [Text] -> Doc
genFnHead fnName params = fName <+> align (docIntercalate softline docParams <+> "=")
  where
    docParams = map psVar params
    fName = strictText fnName

genFnBody :: [PSParam] -> Req PSType -> Doc
genFnBody rParams req = "do"
    </> indent 2 (
          "spOpts_' <- ask"
      </> "let spParams_ = view (_params <<< _Newtype) spOpts_'"
      </> "let encodeOptions = view _encodeJson spOpts_'"
      </> "let decodeOptions = view _decodeJson spOpts_'"
      </> genGetReaderParams rParams
      </> hang 6 ("let httpMethod = fromString" <+> dquotes (req ^. reqMethod ^. to T.decodeUtf8 ^. to strictText))
      </> genBuildQueryArgs (req ^. reqUrl ^. queryStr)
      </> hang 6 ("let reqUrl ="     <+> genBuildURL (req ^. reqUrl))
      </> "let reqHeaders =" </> indent 6 (req ^. reqHeaders ^. to genBuildHeaders)
      </> "let affReq =" <+> hang 2 ( "defaultRequest" </>
            "{ method ="  <+> "httpMethod"
        </> ", url ="     <+> "reqUrl"
        </> ", headers =" <+> "defaultRequest.headers <> reqHeaders"
        </> case req ^. reqBody of
              Nothing -> "}"
              Just _  -> ", content =" <+> "Just $ string $ encodeJSON reqBody" </> "}"
      )
      </> "r <- ajax decode affReq"
      </> "pure r.body"
    ) <> line

genBuildURL :: Url PSType -> Doc
genBuildURL url = psVar baseURLId <+> "<>"
    <+> genBuildPath (url ^. path ) <+> "<>" <+> "queryString"

----------
genBuildPath :: Path PSType -> Doc
genBuildPath = docIntercalate (softline <> "<> \"/\" <> ") . map (genBuildSegment . unSegment)

genBuildSegment :: SegmentType PSType -> Doc
genBuildSegment (Static (PathSegment seg)) = dquotes $ strictText (textURLEncode False seg)
genBuildSegment (Cap arg) = "encodeURLPiece spOpts_'" <+> arg ^. argName ^. to unPathSegment ^. to psVar

genBuildQueryArgs :: [QueryArg PSType] -> Doc
genBuildQueryArgs [] = "let queryString = \"\""
genBuildQueryArgs args = "let queryArgs = catMaybes [" </> (indent 2 (docIntercalate ("," <> softline) . map genBuildQueryArg $ args)) </> "]"
                  </> "let queryString = if null queryArgs then \"\" else \"?\" <> (joinWith \"&\" queryArgs)"

----------
genBuildQueryArg :: QueryArg PSType -> Doc
genBuildQueryArg arg = case arg ^. queryArgType of
    Normal -> genQueryEncoding "encodeQueryItem spOpts_'" "<$>"
    Flag   -> genQueryEncoding "encodeQueryItem spOpts_'" "<$> Just"
    List   -> genQueryEncoding "encodeListQuery spOpts_'" "<$> Just"
  where
    argText = arg ^. queryArgName ^. argName ^. to unPathSegment
    encodedArgName = strictText . textURLEncode True $ argText
    genQueryEncoding fn operator = fn <+> dquotes encodedArgName <+> operator <+> psVar argText

-----------

genBuildHeaders :: [HeaderArg PSType] -> Doc
genBuildHeaders = list . map genBuildHeader

genBuildHeader :: HeaderArg PSType -> Doc
genBuildHeader (HeaderArg arg) = let
    argText = arg ^. argName ^. to unPathSegment
    encodedArgName = strictText . textURLEncode True $ argText
  in
    align $ "RequestHeader " <> dquotes encodedArgName
      <+> parens ("encodeHeader spOpts_'" <+> psVar argText)
genBuildHeader (ReplaceHeaderArg _ _) = error "ReplaceHeaderArg - not yet implemented!"

reqsToImportLines :: [Req PSType] -> ImportLines
reqsToImportLines = typesToImportLines Map.empty . Set.fromList . concatMap reqToPSTypes

reqToPSTypes :: Req PSType -> [PSType]
reqToPSTypes req = map _pType (reqToParams req) ++ maybeToList (req ^. reqReturnType)

-- | Extract all function parameters from a given Req.
reqToParams :: Req PSType -> [Param PSType]
reqToParams req = Param baseURLId psString
               : fmap headerArgToParam (req ^. reqHeaders)
               ++ maybeToList (reqBodyToParam (req ^. reqBody))
               ++ urlToParams (req ^. reqUrl)

urlToParams :: Url PSType -> [Param PSType]
urlToParams url = mapMaybe (segmentToParam . unSegment) (url ^. path) ++ map queryArgToParam (url ^. queryStr)

segmentToParam :: SegmentType f -> Maybe (Param f)
segmentToParam (Static _) = Nothing
segmentToParam (Cap arg) = Just Param {
    _pType = arg ^. argType
  , _pName = arg ^. argName ^. to unPathSegment
  }

mkPsMaybe :: PSType -> PSType
mkPsMaybe t = TypeInfo "" "" "Maybe" [t]

queryArgToParam :: QueryArg PSType -> Param PSType
queryArgToParam arg = Param {
    _pType = paramType
  , _pName = arg ^. queryArgName ^. argName ^. to unPathSegment
  }
  where
    paramType = case arg ^. queryArgType of
      Normal -> mkPsMaybe (arg ^. queryArgName ^. argType)
      _ -> arg ^. queryArgName ^. argType

headerArgToParam :: HeaderArg PSType -> Param PSType
headerArgToParam (HeaderArg arg) = Param {
    _pName = arg ^. argName ^. to unPathSegment
  , _pType = arg ^. (argType . typeParameters . to head)
  }
headerArgToParam (ReplaceHeaderArg _ _) = error "We do not support ReplaceHeaderArg - as I have no idea what this is all about."

reqBodyToParam :: Maybe f -> Maybe (Param f)
reqBodyToParam = fmap (Param "reqBody")

docIntercalate :: Doc -> [Doc] -> Doc
docIntercalate i = mconcat . punctuate i


textURLEncode :: Bool -> Text -> Text
textURLEncode spaceIsPlus = T.decodeUtf8 . urlEncode spaceIsPlus . T.encodeUtf8

-- | Little helper for generating valid variable names
psVar :: Text -> Doc
psVar = strictText . toPSVarName
