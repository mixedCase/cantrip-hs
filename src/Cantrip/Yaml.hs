{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | Read YAML files into the same Aeson values and records used by JSON
scripts. YAML uses YAML 1.1 scalar resolution, so quote strings such as @NO@
when they must not be read as booleans.
-}
module Cantrip.Yaml (
    -- * Files
    readYamlFile,
    readYamlFileAs,
) where

import Cantrip.Core (failWith)
import Control.Exception (SomeException, catch)
import Data.Aeson (FromJSON, Value)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Y

-- | Read a YAML file as an Aeson 'Value', for use with the JSON accessors.
readYamlFile :: Text -> IO Value
readYamlFile = readYamlFileAs

{- | Read a YAML file and decode it with its 'FromJSON' instance. File and
parse failures name the path; parse errors include their line and column.
Duplicate mapping keys fail instead of being silently overwritten.
-}
readYamlFileAs :: (FromJSON a) => Text -> IO a
readYamlFileAs path = do
    result <-
        Y.decodeFileWithWarnings (T.unpack path)
            `catch` \(e :: SomeException) ->
                failWith ("cannot read file: " <> path <> ": " <> T.pack (take 120 (show e)))
    case result of
        Left e -> failWith ("invalid YAML: " <> path <> ": " <> T.pack (Y.prettyPrintParseException e))
        Right (warnings, value)
            | null warnings -> return value
            | otherwise -> failWith ("invalid YAML: " <> path <> ": " <> T.pack (show warnings))
