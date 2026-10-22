-- SPDX-License-Identifier: BSD-3-Clause

{- | Umbrella: the single import for scripts. @import Cantrip@
brings the modules below plus the types and helpers every script needs:
'Text', 'ByteString', JSON and YAML values, and @Maybe@ plumbing; JSON
combinators come from "Cantrip.Json".
@when@/@unless@/@forM_@.
-}
module Cantrip (
    module Cantrip.Core,
    module Cantrip.Cli,
    module Cantrip.Json,
    module Cantrip.Yaml,
    module Cantrip.Encoding,
    module Cantrip.Http,
    module Cantrip.Shell,
    module Cantrip.Fs,
    module Cantrip.Time,

    -- * Prelude
    Text,
    ByteString,
    encodeUtf8,
    Value (..),
    object,
    toJSON,
    catMaybes,
    fromMaybe,
    listToMaybe,
    mapMaybe,
    when,
    unless,
    forM_,
) where

import Cantrip.Cli
import Cantrip.Core
import Cantrip.Encoding
import Cantrip.Fs
import Cantrip.Http
import Cantrip.Json
import Cantrip.Shell
import Cantrip.Time
import Cantrip.Yaml
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), object, toJSON)
import Data.ByteString (ByteString)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
