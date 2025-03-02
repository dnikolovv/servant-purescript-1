{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}

module Servant.PureScript
  ( HasBridge,
    DefaultBridge,
    Settings (..),
    addGlobalHeader,
    addGlobalQueryParam,
    addSwitch,
    addTypes,
    apiModuleName,
    defaultBridge,
    defaultBridgeProxy,
    defaultSettings,
    generate,
    generateWithSettings,
    globalHeaders,
    globalQueryParams,
    jsonParseHeader,
    jsonParseUrlPiece,
    jsonToHeader,
    jsonToUrlPiece,
    mkPackageName,
    languageBridge,
    packageName,
    psBridgeSwitches,
    psTypes,
    standardImports,
    toHeader,
    toPathSegment,
    toQueryValue,
    uriType,
    UriType (..)
  )
where

import Data.Aeson
import Data.Bifunctor
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Language.PureScript.Bridge hiding (psTypes)
import Servant.Foreign hiding (Normal, toHeader)
import Servant.PureScript.CodeGen
import Servant.PureScript.Internal
import System.Directory
import System.FilePath
import System.IO (IOMode (..), withFile)
import Text.PrettyPrint.Mainland (hPutDocLn)
import qualified Data.Set as Set
import Control.Monad (guard)
import Data.Maybe (fromMaybe)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Functor (($>))
import Control.Lens
import qualified Data.Map as Map

-- | Standard entry point - just create a purescript module with default settings
--   for accessing the servant API.
generate ::
  forall bridgeSelector api.
  ( HasForeign (PureScript bridgeSelector) PSType api,
    GenerateList PSType (Foreign PSType api),
    HasBridge bridgeSelector
  ) =>
  FilePath ->
  Proxy bridgeSelector ->
  Proxy api ->
  IO ()
generate = generateWithSettings defaultSettings

generateWithSettings ::
  forall bridgeSelector api.
  ( HasForeign (PureScript bridgeSelector) PSType api,
    GenerateList PSType (Foreign PSType api),
    HasBridge bridgeSelector
  ) =>
  Settings ->
  FilePath ->
  Proxy bridgeSelector ->
  Proxy api ->
  IO ()
generateWithSettings opts@Settings {..} root pBr pAPI = do
  T.putStrLn "\nCreating your PureScript Types..."
  writePSTypesWithNamespace _psBridgeSwitches _packageName root bridge
    $ interceptType . getSumTypeByTypeInfo
    <$> Set.toList _psTypes
  T.putStrLn "\nSuccessfully created your PureScript types!"
  T.putStrLn "\nCreating your API client module..."
  writeModule _apiModuleName
  T.putStrLn "\nSuccessfully created your client module!"
  T.putStrLn "Please make sure you have purescript-servant-support and purescript-bridge-json-helpers installed\n"
  where
    bridge = languageBridge pBr
    interceptType = interceptHeader . interceptQueryParam . interceptPathSegment
    interceptHeader = interceptor headerTypes toHeader
    interceptQueryParam = interceptor queryTypes toQueryValue
    interceptPathSegment = interceptor pathTypes toPathSegment
    apiList = apiToList pAPI pBr
    flatArgTypes = argType . to flattenTypeInfo . traversed
    headerTypes = apiTypesOf $ reqHeaders . traversed . headerArg . flatArgTypes
    queryTypes = apiTypesOf $ reqUrl . queryStr . traversed . queryArgName . flatArgTypes
    pathTypes = apiTypesOf $ reqUrl . path . traversed . to unSegment . _Cap . flatArgTypes
    apiTypesOf l = Set.fromList $ apiList ^.. traversed . l

    interceptor include f sumType
      | Set.member (sumType ^. sumTypeInfo . to bridge) include = f sumType
      | otherwise = sumType

    writeModule :: Text -> IO ()
    writeModule mName =
      let baseFileName = root </> joinPath (map T.unpack $ T.splitOn "." mName)
          pursModuleFile = baseFileName <> ".purs"
          pursModulePath = pursModuleFile
          mDir = takeDirectory baseFileName
          contents = genModule opts apiList
       in do
            unlessM (doesDirectoryExist mDir) $ createDirectoryIfMissing True mDir
            withFile pursModulePath WriteMode $ flip hPutDocLn contents

-- | Use this function for implementing 'parseUrlPiece' in your FromHttpApiData instances
--   in order to be compatible with the generated PS code.
--
-- >
-- > instance ToHttpApiData MyDataType where
-- >   toUrlPiece = jsonToUrlPiece
-- >   toHeader   = jsonToHeader
-- >
-- > instance FromHttpApiData MyDataType where
-- >   parseUrlPiece = jsonParseUrlPiece
-- >   parseHeader   = jsonParseHeader
-- >
jsonParseUrlPiece :: FromJSON a => Text -> Either Text a
jsonParseUrlPiece = jsonParseHeader . T.encodeUtf8

-- | Use this function for implementing 'toUrlPiece' in your ToHttpApiData instances
--   in order to be compatible with the generated PS code.
jsonToUrlPiece :: ToJSON a => a -> Text
jsonToUrlPiece = T.decodeUtf8 . jsonToHeader

-- | Use this function for implementing 'parseHeader' in your FromHttpApiData instances
--   in order to be compatible with the generated PS code.
jsonParseHeader :: FromJSON a => ByteString -> Either Text a
jsonParseHeader = first T.pack . eitherDecodeStrict

-- | Use this function for implementing 'toHeader' in your ToHttpApiData instances
--   in order to be compatible with the generated PS code.
jsonToHeader :: ToJSON a => a -> ByteString
jsonToHeader = BS.toStrict . encode

toHeader :: SumType lang -> SumType lang
toHeader = mkToURIData "Header"

toQueryValue :: SumType lang -> SumType lang
toQueryValue = mkToURIData "QueryValue"

toPathSegment :: SumType lang -> SumType lang
toPathSegment = mkToURIData "PathSegment"

mkToURIData :: Text -> SumType lang -> SumType lang
mkToURIData name (SumType t cs is) = SumType t cs $ mkInstance : is
  where
    mkInstance = Custom $ CustomInstance mkConstraints mkHead mkImplementation
    mkConstraints = []
    mkHead = TypeInfo "purescript-servant-support" "Servant.PureScript" ("To" <> name) [t]
    mkImplementation = fromMaybe useShow $
      (guard canDeriveNewtype $> DeriveNewtype)
        <|> (guard canUseEncodeJson $> useEncodeJson)
    canDeriveNewtype = Newtype `elem` is && isn'tRecord cs
    isn'tRecord [DataConstructor _ (Normal (ty :| []))] = ty ^. typeName . to isKnownCompatibleType
    isn'tRecord _ = False
    canUseEncodeJson = Json `elem` is
    isKnownCompatibleType "String" = True
    isKnownCompatibleType _ = True
    useShow = mkExplicit "show" Map.empty
    useEncodeJson = mkExplicit "encodeJson" $ importsFromList
      [ImportLine "Data.Argonaut" $ Set.fromList ["encodeJson"]
      ,ImportLine "Servant.PureScript" $ Set.fromList [methodName]
      ]
    methodName = "to" <> name
    mkExplicit body importLines =
      Explicit [InstanceMember methodName [] (methodName <> " <<< " <> body) [] importLines]

