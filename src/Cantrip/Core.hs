-- SPDX-License-Identifier: BSD-3-Clause

-- | Small shared vocabulary: errors, env, time.
module Cantrip.Core (
    ScriptError (..),
    failWith,
    expect,
    envOr,
    nowMs,
) where

import Control.Exception (Exception (..), throwIO)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Environment (lookupEnv)

{- | Uniform failure for scripts. 'Cantrip.Cli.jsonScript' and
'Cantrip.Cli.script' render it; uncaught, GHC prints just the reason.
-}
newtype ScriptError = ScriptError Text deriving (Show)

instance Exception ScriptError where
    displayException (ScriptError reason) = T.unpack reason

-- | Throw a t'ScriptError'.
failWith :: Text -> IO a
failWith = throwIO . ScriptError

-- | The value in a 'Just', or 'failWith' the message on 'Nothing'.
expect :: Text -> Maybe a -> IO a
expect reason = maybe (failWith reason) return

{- | Environment variable, 'Text' like the rest of the API. Falls back
to the default when unset.
-}
envOr :: Text -> Text -> IO Text
envOr var def = do
    m <- lookupEnv (T.unpack var)
    return (maybe def T.pack m)

-- | Current time in integer milliseconds.
nowMs :: IO Integer
nowMs = do
    t <- getPOSIXTime
    return (floor (t * 1000))
