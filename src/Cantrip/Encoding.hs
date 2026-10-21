-- SPDX-License-Identifier: BSD-3-Clause

{- | Bytes as text and back: hex, base64, and UTF-8.

Decoders return 'Nothing' on bad input; add a message with
'Cantrip.Core.expect'. They ignore whitespace, as @xxd -r -p@ and
@base64 -d@ do, so wrapped command output decodes as it is.
-}
module Cantrip.Encoding (
    toHex,
    fromHex,
    toBase64,
    fromBase64,
    fromUtf8,
    decodeUtf8Lenient,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Base64 as Base64
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, decodeUtf8', decodeUtf8Lenient, encodeUtf8)

-- | Lowercase hex, like @xxd -p@ (without its line wrapping).
toHex :: ByteString -> Text
toHex = decodeLatin1 . Base16.encode

-- | Hex in either case, like @xxd -r -p@.
fromHex :: Text -> Maybe ByteString
fromHex = either (const Nothing) Just . Base16.decode . encodeUtf8 . T.filter (not . isSpace)

-- | Standard padded base64, like @base64 -w0@.
toBase64 :: ByteString -> Text
toBase64 = decodeLatin1 . Base64.encode

-- | Standard padded base64, like @base64 -d@.
fromBase64 :: Text -> Maybe ByteString
fromBase64 = either (const Nothing) Just . Base64.decode . encodeUtf8 . T.filter (not . isSpace)

{- | Bytes that must be UTF-8: 'Nothing' if they are not. Use
'decodeUtf8Lenient' instead to replace invalid bytes with U+FFFD.
-}
fromUtf8 :: ByteString -> Maybe Text
fromUtf8 = either (const Nothing) Just . decodeUtf8'
