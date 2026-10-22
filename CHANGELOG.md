# Changelog

All notable changes to this project will be documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Cantrip.Yaml`: `readYamlFile` and `readYamlFileAs`, using Aeson values and
  `FromJSON` decoding; duplicate mapping keys fail loudly.
- New dependency: `yaml` (BSD-3-Clause, libyaml). It follows YAML 1.1, so
  unquoted `NO` reads as `False`.

## [0.1.0] - 2026-10-21

Initial release.

### Added

- `lib.mkCantrip`: a script, or a directory of modules, as a Nix package, with
  extra Haskell libraries per script.
- `cantrip`: a runner for `#!/usr/bin/env cantrip` scripts. It compiles a script
  on first use and caches the binary by content and compiler. `lib.mkRunner`
  builds one with extra Haskell packages.
- `Cantrip`: umbrella module that re-exports everything below plus `Text`,
  `ByteString`, the core JSON types and combinators, and common `Data.Maybe` and
  `Control.Monad` helpers.
- `Cantrip.Shell`: the `[sh|...|]` quasi-quoter, `cmd`, `shell`, `|>`; `run`,
  `capture`, `captureLines`, `captureJson`, `captureBytes`, `forLines`,
  `succeeds`, `exitCode`; the settings `<<<`, `withStdinBytes`, `inDir`,
  `withEnv`, `quiet`, `withTimeout`, `errorTail`; `showCmd`, `echo`, `tshow`;
  and `CANTRIP_TRACE`.
- `Cantrip.Fs`: `glob`, `listDir`, `readText`, `writeText`, `appendText`,
  `exists`, `mkdirP`, `copy`, `move`, `remove`, `withTempDir`, `which`, `cd`,
  `pwd`, `</>`, `atomicWriteFile`, `modifyJsonFile`, `withLockDir`.
- `Cantrip.Cli`: `jsonScript` and `script` entry points; `parseArgs` (generated
  usage) and `parseArgsWith` (your own), read with `switch`, `option`,
  `readOption`, `positional`, `positionals`, `usageText`.
- `Cantrip.Encoding`: `toHex`, `fromHex`, `toBase64`, `fromBase64`, `fromUtf8`,
  `decodeUtf8Lenient`.
- `Cantrip.Core`: `ScriptError`, `failWith`, `expect`, `envOr`, `nowMs`.
- `Cantrip.Json`: `readJsonFile`, `at`, `str`, `num`, `int`, `obj`, `arr`,
  `upsert`, `merge`, `jwtPayload`, `jwtClaim`, `encodePretty`.
- `Cantrip.Http`: `http`, `request`, `expectJson`, `orNothing`, `userAgent`, and
  re-exports from `Network.HTTP.Simple`.
- `Cantrip.Time`: `parseIso8601Ms`, `formatIso8601Ms`.
