{-# LANGUAGE OverloadedStrings #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | Script entry points and argument parsing. 'jsonScript' prints one
@{"ok": ...}@ JSON line, a contract easy to consume from another
program; 'script' is the plain-text variant. Both render
t'Cantrip.Core.ScriptError' (and any other synchronous exception) once,
at the top, so script bodies just 'Cantrip.Core.failWith'.

'parseArgs' is a small getopt: switches, options with values,
positionals, and a generated @--help@. Its errors are t'Cantrip.Core.ScriptError's,
so they come out in the same format as every other failure.

Arguments are 'Text'. A file name that is not valid UTF-8 has its
invalid bytes replaced with U+FFFD, so it no longer names the same file.
-}
module Cantrip.Cli (
    jsonScript,
    script,

    -- * Arguments
    Args,
    parseArgs,
    parseArgsWith,
    switch,
    option,
    readOption,
    positional,
    positionals,
    usageText,
) where

import Cantrip.Core (ScriptError (..), failWith)
import Control.Exception (SomeAsyncException, SomeException (..), displayException, fromException, throwIO, try)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Char (isSpace, isUpper)
import Data.List (stripPrefix)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.IO (BufferMode (..), hFlush, hSetBuffering, hSetEncoding, stderr, stdin, stdout, utf8)
import System.Process (CmdSpec (..))
import System.Process.Typed (ExitCodeException (..))
import System.Process.Typed.Internal (ProcessConfig (..))
import Text.Read (readMaybe)

{- | Run the body with the CLI arguments and print one JSON line.
An object result gains @"ok": true@; 'Null' prints @{"ok":true}@; any
other value lands under @"result"@. Failures print
@{"ok":false,"reason":...}@ and exit 1.

Stdout carries only that line: while the body runs, stdout (and so the
output of any command it starts, and @--help@) goes to stderr.
-}
jsonScript :: ([Text] -> IO Value) -> IO ()
jsonScript body = do
    out <- hDuplicate stdout
    hDuplicateTo stderr stdout
    standardHandles
    outcome <- runBody body
    let emit v = BL8.hPutStrLn out (encode v) >> hFlush out
    case outcome of
        Right value -> emit (okResult value)
        Left reason -> emit (object ["ok" .= False, "reason" .= reason]) >> exitFailure

{- | Run the body; on failure print @error: reason@ to stderr and exit 1.
The standard handles are UTF-8 whatever the locale, and stdout is
line-buffered, so the script's output and that of the commands it runs
stay in order.
-}
script :: ([Text] -> IO ()) -> IO ()
script body = do
    standardHandles
    outcome <- runBody body
    case outcome of
        Right () -> return ()
        Left reason -> BS.hPut stderr (encodeUtf8 ("error: " <> reason <> "\n")) >> exitFailure

-- | UTF-8 whatever the locale, and line-buffered so output interleaves with child processes'.
standardHandles :: IO ()
standardHandles = do
    mapM_ (`hSetEncoding` utf8) [stdin, stdout, stderr]
    hSetBuffering stdout LineBuffering

okResult :: Value -> Value
okResult (Object o) = Object (KM.insert "ok" (Bool True) o)
okResult Null = object ["ok" .= True]
okResult other = object ["ok" .= True, "result" .= other]

-- | Parsed command line. Read it with 'switch', 'option', 'readOption', 'positional', 'positionals'.
data Args = Args
    { flags :: [(String, Bool)]
    , required :: [String]
    , usageText :: Text
    -- ^ The usage text 'parseArgs' printed for @--help@, for the script's own errors.
    , switches :: [String]
    , options :: [(String, String)]
    , given :: [String]
    }

data Entry = Switch String | Opt String String | Pos String | Rest String

{- | @parseArgs spec argv@. Each spec entry is one of:

* @"dry-run"@: a switch, @--dry-run@.
* @"retries=N"@: an option with a value, @--retries N@ (@"retries="@
  shows the value as @VALUE@).
* @"FILE"@ (uppercase): a required positional argument, read with 'positional'.
* @"FILES..."@: any number of further positionals, last in the spec.

> args <- parseArgs ["dry-run", "retries=N", "FILE"] argv
> -- usage: tool [--dry-run] [--retries N] FILE

* @--name@ and @-name@ are the same; values come as @--name VALUE@ or
  @--name=VALUE@; a repeated option keeps its last value.
* @--@ ends the options; @-@ alone is a positional.
* @-h@ or @--help@ prints the usage line (built from the spec and the
  program name) to stdout and exits 0.
* An unknown option, a missing value, a value given to a switch, or the
  wrong number of positionals throws t'Cantrip.Core.ScriptError' with
  the usage line appended.
-}
parseArgs :: [Text] -> [Text] -> IO Args
parseArgs spec argv = do
    prog <- getProgName
    parseArgsWith (T.pack (unwords ("usage:" : prog : map render (flagsFirst entries)))) spec argv
  where
    entries = map (entry . T.unpack) spec
    flagsFirst es = [e | e <- es, isFlag e] ++ [e | e <- es, not (isFlag e)]
    isFlag e = case e of Switch _ -> True; Opt _ _ -> True; _ -> False
    render (Switch n) = "[" ++ dashed n ++ "]"
    render (Opt n meta) = "[" ++ dashed n ++ " " ++ meta ++ "]"
    render (Pos n) = n
    render (Rest n) = "[" ++ n ++ "...]"
    dashed n = (if length n == 1 then "-" else "--") ++ n

-- | 'parseArgs' with your own usage text for @--help@ and errors.
parseArgsWith :: Text -> [Text] -> [Text] -> IO Args
parseArgsWith usage spec = parseStrings usage (map T.unpack spec) . map T.unpack

parseStrings :: Text -> [String] -> [String] -> IO Args
parseStrings usage spec argv
    | misordered = error "Cantrip.Cli: a NAME... entry must come after every positional in the parseArgs spec"
    | any (`elem` ["-h", "--help"]) (takeWhile (/= "--") argv) = BS.putStr (encodeUtf8 (usage <> "\n")) >> exitSuccess
    | otherwise = either (\e -> failWith (T.pack e <> "\n" <> usage)) return (counted =<< go (Args known names usage [] [] []) argv)
  where
    entries = map entry spec
    known = [(n, False) | Switch n <- entries] ++ [(n, True) | Opt n _ <- entries]
    names = [n | Pos n <- entries]
    variadic = any isRest entries
    misordered = not (null [() | Pos _ <- dropWhile (not . isRest) entries])
    isRest e = case e of Rest _ -> True; _ -> False
    counted acc
        | length ps < length names = Left ("missing argument: " ++ names !! length ps)
        | not variadic && length ps > length names = Left ("unexpected argument: " ++ ps !! length names)
        | otherwise = Right acc
      where
        ps = given acc
    go acc [] = Right acc
    go acc ("--" : rest) = Right acc{given = given acc ++ rest}
    go acc (tok@('-' : _ : _) : rest) =
        let (name, inline) = break (== '=') (bare tok)
            withValue v = acc{options = (name, v) : options acc}
         in case (lookup name known, inline, rest) of
                (Nothing, _, _) -> Left ("unknown option: " ++ tok)
                (Just False, "", _) -> go acc{switches = name : switches acc} rest
                (Just False, _, _) -> Left ("--" ++ name ++ " takes no value")
                (Just True, '=' : v, _) -> go (withValue v) rest
                (Just True, _, v : rest') -> go (withValue v) rest'
                (Just True, _, []) -> Left ("--" ++ name ++ " needs a value")
    go acc (arg : rest) = go acc{given = given acc ++ [arg]} rest

entry :: String -> Entry
entry s = case s of
    c : _ | isUpper c -> maybe (Pos s) Rest (stripSuffix "..." s)
    _ -> case break (== '=') (bare s) of
        (name, '=' : meta) -> Opt name (if null meta then "VALUE" else meta)
        (name, _) -> Switch name
  where
    stripSuffix suffix xs = reverse <$> stripPrefix (reverse suffix) (reverse xs)

-- | Whether a switch was given.
switch :: Text -> Args -> Bool
switch name args = checked False n args `seq` elem (bare n) (switches args)
  where
    n = T.unpack name

-- | An option's value, if given.
option :: Text -> Args -> Maybe Text
option name args = checked True n args `seq` T.pack <$> lookup (bare n) (options args)
  where
    n = T.unpack name

{- | An option's value parsed with 'Read' (numbers, mostly; use 'option'
for text). t'Cantrip.Core.ScriptError' if it does not parse.
-}
readOption :: (Read a) => Text -> Args -> IO (Maybe a)
readOption name args = case option name args of
    Nothing -> return Nothing
    Just v -> maybe (failWith ("--" <> T.dropWhile (== '-') name <> ": invalid value: " <> v)) (return . Just) (readMaybe (T.unpack v))

-- | A required positional argument, by its spec name. 'parseArgs' already checked it is there.
positional :: Text -> Args -> Text
positional name args =
    maybe
        (error ("Cantrip.Cli: " ++ T.unpack name ++ " is not a required positional in the parseArgs spec"))
        T.pack
        (lookup (T.unpack name) (zip (required args) (given args)))

-- | Every positional argument, in order.
positionals :: Args -> [Text]
positionals = map T.pack . given

-- | Asking for a name the spec never declared is a bug in the script, not bad input.
checked :: Bool -> String -> Args -> ()
checked takesValue name args
    | lookup (bare name) (flags args) == Just takesValue = ()
    | otherwise = error ("Cantrip.Cli: " ++ name ++ " is not declared as " ++ (if takesValue then "an option" else "a switch") ++ " in the parseArgs spec")

bare :: String -> String
bare = dropWhile (== '-')

-- | Exit codes and async exceptions (Ctrl-C, timeouts) pass through.
runBody :: ([Text] -> IO a) -> IO (Either Text a)
runBody body = do
    result <- try (body . map T.pack =<< getArgs)
    case result of
        Right a -> return (Right a)
        Left e
            | Just (ScriptError reason) <- fromException e -> return (Left reason)
            | Just failed <- fromException e -> return (Left (commandFailed failed))
            | passThrough e -> throwIO e
            | SomeException inner <- e -> return (Left (T.pack (take 200 (displayException inner))))
  where
    passThrough :: SomeException -> Bool
    passThrough e =
        isJust (fromException e :: Maybe ExitCode)
            || isJust (fromException e :: Maybe SomeAsyncException)

{- | typed-process's own message carries the full command line and the
captured output, where tokens and passwords tend to be; keep the name.
-}
commandFailed :: ExitCodeException -> Text
commandFailed failed = T.pack (described (pcCmdSpec (eceProcessConfig failed)) ++ " (" ++ code (eceExitCode failed) ++ ")")
  where
    described (RawCommand cmd _) = "command failed: " ++ cmd
    described (ShellCommand line) = "shell command failed: " ++ takeWhile (not . isSpace) (dropWhile isSpace line) ++ " ..."
    code (ExitFailure n) = "exit " ++ show n
    code ExitSuccess = "exit 0"
