-- File auto generated by purescript-bridge! --
module ServerTypes where

import Prelude

import Control.Lazy (defer)
import Data.Argonaut (encodeJson, jsonNull)
import Data.Argonaut.Decode (class DecodeJson)
import Data.Argonaut.Decode.Aeson ((</$\>), (</*\>), (</\>))
import Data.Argonaut.Encode (class EncodeJson)
import Data.Argonaut.Encode.Aeson ((>$<), (>/\<))
import Data.Generic.Rep (class Generic)
import Data.Lens (Iso', Lens', Prism', iso, prism')
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap)
import Data.Show.Generic (genericShow)
import Data.Tuple.Nested ((/\))
import Servant.PureScript (class ToHeader, class ToQueryValue, toQueryValue)
import Type.Proxy (Proxy(Proxy))
import Data.Argonaut.Decode.Aeson as D
import Data.Argonaut.Encode.Aeson as E
import Data.Map as Map

newtype Hello = Hello { message :: String }

instance ToQueryValue Hello where
  toQueryValue = toQueryValue <<< encodeJson

derive instance Eq Hello

derive instance Ord Hello

instance Show Hello where
  show a = genericShow a

instance EncodeJson Hello where
  encodeJson = defer \_ -> E.encode $ unwrap >$< (E.record
                                                 { message: E.value :: _ String })

instance DecodeJson Hello where
  decodeJson = defer \_ -> D.decode $ (Hello <$> D.record "Hello" { message: D.value :: _ String })

derive instance Generic Hello _

derive instance Newtype Hello _

--------------------------------------------------------------------------------

_Hello :: Iso' Hello {message :: String}
_Hello = _Newtype

--------------------------------------------------------------------------------

newtype TestHeader = TestHeader String

derive newtype instance ToHeader TestHeader

instance EncodeJson TestHeader where
  encodeJson = defer \_ -> E.encode $ unwrap >$< E.value

instance DecodeJson TestHeader where
  decodeJson = defer \_ -> D.decode $ (TestHeader <$> D.value)

derive instance Generic TestHeader _

derive instance Newtype TestHeader _

--------------------------------------------------------------------------------

_TestHeader :: Iso' TestHeader String
_TestHeader = _Newtype
