#!/usr/bin/env cantrip
-- Increment a counter in an existing JSON file, safe against concurrent runs.
import Cantrip

main :: IO ()
main = script $ \argv -> do
    args <- parseArgs ["FILE", "KEY"] argv
    let key = positional "KEY" args
    modifyJsonFile (positional "FILE" args) 0o644 $ \v ->
        return (upsert key (Number (fromInteger (maybe 1 (+ 1) (int key v)))) v)
