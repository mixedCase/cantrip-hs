{-# LANGUAGE OverloadedStrings #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | HTTPS for scripts, on @http-conduit@'s "Network.HTTP.Simple".
Build requests with its setters, send them with 'http', branch on
'getResponseStatusCode', and decode with 'expectJson'. A non-2xx status
is a value, never an exception; only transport failures throw, as
t'Cantrip.Core.ScriptError'. 'orNothing' opts a call into 'Nothing' on HTTP and script failures.
-}
module Cantrip.Http (
    -- * Sending
    http,
    userAgent,

    -- * Decoding
    request,
    expectJson,
    orNothing,

    -- * Re-exported from "Network.HTTP.Simple"
    Request,
    Response,
    Header,
    HeaderName,
    RequestHeaders,
    ResponseHeaders,
    Query,
    HttpException (..),
    defaultRequest,
    parseRequest,
    parseRequest_,
    setRequestMethod,
    setRequestSecure,
    setRequestHost,
    setRequestPort,
    setRequestPath,
    addRequestHeader,
    getRequestHeader,
    setRequestHeader,
    setRequestHeaders,
    setRequestQueryString,
    getRequestQueryString,
    addToRequestQueryString,
    setRequestBody,
    setRequestBodyJSON,
    setRequestBodyLBS,
    setRequestBodyFile,
    setRequestBodyURLEncoded,
    setRequestBasicAuth,
    setRequestBearerAuth,
    setRequestResponseTimeout,
    getResponseStatus,
    getResponseStatusCode,
    getResponseHeader,
    getResponseHeaders,
    getResponseBody,
) where

import Cantrip.Core (ScriptError (..), failWith)
import Control.Exception (catch, try)
import Data.Aeson (FromJSON, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Request (..))
import Network.HTTP.Simple
import Network.HTTP.Types.Header (HeaderName)

-- | Sent by 'http' when the request has no @User-Agent@ of its own.
userAgent :: BS.ByteString
userAgent = "cantrip-hs/0.1.0"

{- | Send a request and read the whole body. Any status comes back as a
'Response'; DNS, TLS, timeout, and bad-URL failures throw t'Cantrip.Core.ScriptError'.
The message names the host but never the request, so credentials in
headers stay out of logs.
-}
http :: Request -> IO (Response BL.ByteString)
http req = httpLBS withAgent `catch` (failWith . describe)
  where
    withAgent
        | null (getRequestHeader "User-Agent" req) = addRequestHeader "User-Agent" userAgent req
        | otherwise = req
    describe :: HttpException -> Text
    describe (HttpExceptionRequest r content) = T.pack ("http error: " ++ C8.unpack (host r) ++ ": " ++ take 160 (show content))
    describe (InvalidUrlException url reason) = T.pack ("invalid URL: " ++ url ++ ": " ++ reason)

{- | Parse a URL (optionally prefixed with a method, @"POST https://..."@)
into a request; t'Cantrip.Core.ScriptError' on a bad one.
-}
request :: Text -> IO Request
request url = do
    r <- try (parseRequest (T.unpack url)) :: IO (Either HttpException Request)
    case r of
        Left (InvalidUrlException _ reason) -> failWith (T.pack ("invalid URL: " ++ reason))
        Left e -> failWith (T.pack ("bad URL: " ++ take 120 (show e)))
        Right req -> return req

-- | Decode a 2xx JSON body; any other status or a bad body throws t'Cantrip.Core.ScriptError'.
expectJson :: (FromJSON a) => Response BL.ByteString -> IO a
expectJson resp
    | code < 200 || code >= 300 = failWith (T.pack ("http " ++ show code))
    | otherwise = either (failWith . T.pack . ("bad JSON in HTTP response: " ++)) return (eitherDecode (getResponseBody resp))
  where
    code = getResponseStatusCode resp

{- | 'Nothing' instead of a t'Cantrip.Core.ScriptError' or 'HttpException' (the latter
covers 'parseRequest' on a bad URL). Other exceptions still propagate.
For optional reads.
-}
orNothing :: IO a -> IO (Maybe a)
orNothing action = (Just <$> action) `catch` scriptError `catch` httpError
  where
    scriptError (ScriptError _) = return Nothing
    httpError :: HttpException -> IO (Maybe a)
    httpError _ = return Nothing
