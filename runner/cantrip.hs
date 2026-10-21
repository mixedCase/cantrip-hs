{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- cantrip SCRIPT [ARGS...]: run a cantrip script, compiling it on first use.

Put `#!/usr/bin/env cantrip` on a script's first line. The first run (and
the first after each edit) compiles it into the cache, about a second;
every other run starts the cached binary directly. The cache key is the
script's contents plus the GHC's path, so an edit, or a compiler at a new
path, recompiles.

  CANTRIP_GHC     the GHC to compile with (the Nix package sets it to one
                  that has cantrip-hs; point it at your own for more packages)
  XDG_CACHE_HOME  cache location, default ~/.cache; binaries live in cantrip/
-}
import Cantrip
import qualified Data.Text as T
import GHC.Fingerprint (fingerprintFingerprints, fingerprintString, getFileHash)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (dropExtension, takeFileName)
import System.Posix.Process (executeFile, getProcessID)

-- | Changing how scripts are compiled changes this, so old binaries are not reused.
flavour :: String
flavour = "cantrip-runner-1 -O2 -threaded -XOverloadedStrings -XQuasiQuotes"

usage :: Text
usage = "usage: cantrip SCRIPT [ARGS...]\nRuns a cantrip script, compiling it on first use. See the README."

main :: IO ()
main = script $ \case
    [] -> failWith usage
    [flag] | flag `elem` ["-h", "--help"] -> echo usage
    file : args -> do
        ghc <- envOr "CANTRIP_GHC" "ghc"
        root <- cacheRoot
        source <- getFileHash (T.unpack file)
        let key = T.pack (show (fingerprintFingerprints [source, fingerprintString (T.unpack ghc), fingerprintString flavour]))
            name = T.pack (dropExtension' (takeFileName (T.unpack file)))
            binary = root </> key </> name
        cached <- exists binary
        unless cached (compile ghc file root (root </> key) name)
        executeFile (T.unpack binary) False (map T.unpack args) Nothing
  where
    dropExtension' f = if ".hs" `T.isSuffixOf` T.pack f then dropExtension f else f

cacheRoot :: IO Text
cacheRoot = do
    xdg <- envOr "XDG_CACHE_HOME" ""
    home <- envOr "HOME" ""
    case (xdg, home) of
        ("", "") -> failWith "neither XDG_CACHE_HOME nor HOME is set; cantrip needs a cache directory"
        ("", _) -> return (home </> ".cache" </> "cantrip")
        _ -> return (xdg </> "cantrip")

{- | Build in a private directory inside the cache, then rename the binary
into place, so a concurrent run never starts a half-written binary.
-}
compile :: Text -> Text -> Text -> Text -> Text -> IO ()
compile ghc file root keyDir name = do
    -- shortcut: nothing prunes the cache (old versions, or build dirs of a killed compile); add `cantrip --gc` when someone's cache grows.
    pid <- getProcessID
    let build = root </> ("build-" <> tshow pid)
        main' = build </> "Main.hs"
    mkdirP build
    source <- readText file
    -- The LINE pragma makes GHC report errors against the script itself; the
    -- shebang line becomes empty so line numbers stay right.
    let body = case T.lines source of
            first : rest | "#!" `T.isPrefixOf` first -> T.unlines ("" : rest)
            _ -> source
    writeText main' ("{-# LINE 1 \"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" file) <> "\" #-}\n" <> body)
    code <-
        exitCode
            [sh|${ghc} -v0 -O2 -threaded -XOverloadedStrings -XQuasiQuotes -outputdir ${build}/o -o ${build}/${name} ${main'}|]
    unless (code == 0) (remove build >> exitWith (ExitFailure 1))
    mkdirP keyDir
    move (build </> name) (keyDir </> name)
    remove build
