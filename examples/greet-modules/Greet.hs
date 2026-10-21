module Greet (greeting) where

import Cantrip

-- | The greeting for a name.
greeting :: Text -> Text
greeting name = "hello " <> name
