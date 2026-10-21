-- SPDX-License-Identifier: BSD-3-Clause

{- | ISO-8601 timestamps as epoch milliseconds, the lingua franca for
provider payloads ('Cantrip.Core.nowMs' is the clock; these are
the parsing and formatting side). Built on the @iso8601-time@ package.
-}
module Cantrip.Time (
    parseIso8601Ms,
    formatIso8601Ms,
) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.ISO8601 (formatISO8601Millis, parseISO8601)

{- | Parse @2026-09-22T12:00:00Z@ (offsets and fractionals too) into
integer epoch milliseconds. 'Nothing' on anything else.
-}
parseIso8601Ms :: Text -> Maybe Integer
parseIso8601Ms input = do
    utc <- parseISO8601 (T.unpack input)
    return (floor (utcTimeToPOSIXSeconds utc * 1000))

-- | Format integer epoch milliseconds as @YYYY-MM-DDTHH:mm:ss.sssZ@.
formatIso8601Ms :: Integer -> Text
formatIso8601Ms ms =
    T.pack (formatISO8601Millis (posixSecondsToUTCTime (fromInteger ms / 1000)))
