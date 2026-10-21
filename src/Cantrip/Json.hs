{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | JSON files, safe path access, and accessors that always answer.

Read with 'at' (any depth; array indices are numeric keys) or with the
single-key accessors 'str'/'num'/'int'/'obj'/'arr', which answer
'Nothing' on a missing or mistyped field; add defaults with 'fromMaybe'. Update with 'upsert'
and 'merge'. Decode stable shapes into records with the re-exported
'FromJSON' helpers.
-}
module Cantrip.Json (
    -- * Files
    readJsonFile,

    -- * Path access
    at,
    upsert,
    merge,

    -- * Typed accessors
    str,
    num,
    int,
    obj,
    arr,

    -- * Typed decoding
    FromJSON,
    ToJSON,
    eitherDecode,
    decode,
    (.:),
    (.:?),

    -- * JWT
    jwtPayload,
    jwtClaim,

    -- * Writing
    encodePretty,
    (.=),
) where

import Cantrip.Core (failWith)
import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Monad (mfilter, (>=>))
import Data.Aeson (
    FromJSON,
    KeyValue,
    ToJSON,
    Value (..),
    decode,
    eitherDecode,
    object,
    (.:),
    (.:?),
 )
import qualified Data.Aeson as A
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key (Key, fromText)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.ByteString.Base64.URL (decodeUnpadded)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, toBoundedInteger, toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Vector as V
import Data.Word (Word64)
import Text.Read (readMaybe)

-- | Read and decode a JSON file; t'Cantrip.Core.ScriptError' if it is unreadable or not JSON.
readJsonFile :: Text -> IO Value
readJsonFile path = do
    raw <- try (BS.readFile (T.unpack path)) :: IO (Either SomeException BS.ByteString)
    bytes <- case raw of
        Left e -> failWith ("cannot read file: " <> path <> ": " <> T.pack (take 120 (show e)))
        Right b -> return b
    case decode (BL.fromStrict bytes) of
        Just v -> return v
        Nothing -> failWith ("invalid JSON: " <> path)

{- | Look up a path. Object keys, then array indices: @at ["access","meters","0"]@.
'Nothing' on any missing or mistyped step.
-}
at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : keys) value = lookupKey key value >>= at keys

-- | Key lookup: object keys, or numeric array indices.
lookupKey :: Text -> Value -> Maybe Value
lookupKey key (Object o) = KM.lookup (fromText key) o
lookupKey key (Array xs) = readMaybe (T.unpack key) >>= \i -> xs V.!? i
lookupKey _ _ = Nothing

{- | Insert or deep-merge one key. When both the stored and the new value
are objects, they merge recursively; anything else is replaced.
-}
upsert :: Text -> Value -> Value -> Value
upsert key new current = case current of
    Object o -> Object (KM.insert (fromText key) (merge (fromMaybe Null (KM.lookup (fromText key) o)) new) o)
    _ -> Data.Aeson.object [(fromText key, new)]

{- | Deep-merge the new value into the current one. Two objects merge key by
key, recursively; anything else is replaced by the new value.
-}
merge :: Value -> Value -> Value
merge (Object a) (Object b) = Object (KM.unionWith merge a b)
merge _ new = new

-- | A key and value for 'object', as in @object ["name" .= name]@.
(.=) :: (KeyValue e kv, ToJSON v) => Key -> v -> kv
(.=) = (A..=)

infixr 8 .=

-- | String field; numbers and other shapes are not coerced.
str :: Text -> Value -> Maybe Text
str key =
    lookupKey key >=> \case
        String t -> Just t
        _ -> Nothing

{- | Numeric field, as 'Double'. Also accepts numbers sent as strings.
'Nothing' for values that do not fit a finite 'Double'.
-}
num :: Text -> Value -> Maybe Double
num key =
    lookupKey key >=> \case
        Number n -> finite (toRealFloat n)
        String t -> finite =<< readMaybe (T.unpack t)
        _ -> Nothing
  where
    finite = mfilter (\d -> not (isNaN d || isInfinite d)) . Just

{- | Integer field, exact (no 'Double' rounding of 64-bit IDs). Also
accepts integers sent as strings. 'Nothing' outside the signed or
unsigned 64-bit range, so a hostile @1e1000000000@ cannot make it
build a billion-digit 'Integer'.
-}
int :: Text -> Value -> Maybe Integer
int key =
    lookupKey key >=> \case
        Number n -> bounded n
        String s -> readMaybe (T.unpack s) >>= bounded . fromInteger
        _ -> Nothing
  where
    bounded :: Scientific -> Maybe Integer
    bounded n = toInteger <$> (toBoundedInteger n :: Maybe Int64) <|> toInteger <$> (toBoundedInteger n :: Maybe Word64)

-- | Object field as a 'Value' (keep using 'at' on the result).
obj :: Text -> Value -> Maybe Value
obj key value = case lookupKey key value of
    Just o@(Object _) -> Just o
    _ -> Nothing

-- | Array field.
arr :: Text -> Value -> Maybe [Value]
arr key value = case lookupKey key value of
    Just (Array xs) -> Just (V.toList xs)
    _ -> Nothing

{- | Payload segment of a JWT, decoded. 'Nothing' on any shape problem
(bad segments, bad padding, non-JSON).

__The signature is not verified.__ Use this to read claims from a token
you already trust (one your own auth flow just received), never to
authenticate a token someone handed you.
-}
jwtPayload :: Text -> Maybe Value
jwtPayload access = case T.splitOn "." access of
    (_ : payload : _) -> case decodeUnpadded (encodeUtf8 payload) of
        Left _ -> Nothing
        Right raw -> decode (BL.fromStrict raw)
    _ -> Nothing

{- | @jwtClaim access claim field fallback@: @claim.field@ of a JWT
payload, or the fallback. Unverified, like 'jwtPayload'.
-}
jwtClaim :: Text -> Text -> Text -> Text -> Text
jwtClaim access claim field fallback = case jwtPayload access of
    Nothing -> fallback
    Just payload ->
        fromMaybe
            fallback
            ( at [claim, field] payload
                >>= \case
                    String t | not (T.null t) -> Just t
                    _ -> Nothing
            )
