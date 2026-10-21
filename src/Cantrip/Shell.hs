{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | Running commands and pipelines.

Build a 'Cmd' with @[sh|git log -n ${count}|]@, 'cmd', or 'shell', adjust
it with settings like 'inDir' or 'quiet', and run it with 'run',
'capture', 'succeeds' and the rest.

* Commands inherit the script's stdin, stdout and stderr unless a
  function says otherwise ('capture' reads stdout, 'quiet' discards).
  Text goes in and out as UTF-8; 'withStdinBytes' and 'captureBytes'
  are for binary data.
* A pipeline fails if any stage fails, like @set -o pipefail@, except
  that an early stage killed by SIGPIPE (@yes | head@) is not a failure.
* A failure is a t'Cantrip.Core.ScriptError' naming the program and its exit
  status, never its arguments or output; 'errorTail' opts into the end
  of its stderr.
* @CANTRIP_TRACE=1@ prints every command to stderr before it runs, like
  @set -x@. That trace does show arguments.
-}
module Cantrip.Shell (
    -- * Building commands
    Cmd,
    sh,
    cmd,
    shell,
    (|>),
    ToArgs (..),

    -- * Settings
    (<<<),
    withStdinBytes,
    inDir,
    withEnv,
    quiet,
    withTimeout,
    errorTail,

    -- * Running
    run,
    capture,
    captureLines,
    captureJson,
    captureBytes,
    forLines,
    succeeds,
    exitCode,

    -- * Output
    showCmd,
    echo,
    tshow,
) where

import Cantrip.Core (failWith)
import Cantrip.Shell.Syntax
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, catch, finally, throwIO)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (Handle, hFlush, stderr, stdout)
import System.IO.Error (isDoesNotExistError)
import System.Process.Typed (
    ExitCode (..),
    ProcessConfig,
    StreamSpec,
    StreamType (STOutput),
    byteStringInput,
    byteStringOutput,
    createPipe,
    getStderr,
    getStdout,
    inherit,
    nullStream,
    proc,
    setEnv,
    setStderr,
    setStdin,
    setStdout,
    setWorkingDir,
    useHandleClose,
    waitExitCode,
    withProcessTerm,
 )
import qualified System.Timeout as Timeout

infixl 2 <<<

-- | @c <<< text@: feed @text@ (as UTF-8) to the first stage's stdin, like @c <<< "$text"@.
(<<<) :: Cmd -> Text -> Cmd
c <<< text = c{cmdInput = Just (encodeUtf8 text)}

-- | Feed raw bytes to the first stage's stdin, for binary input that is not text.
withStdinBytes :: BS.ByteString -> Cmd -> Cmd
withStdinBytes bytes c = c{cmdInput = Just bytes}

-- | Run in another directory, like @(cd dir && cmd)@. The script's own directory does not change.
inDir :: Text -> Cmd -> Cmd
inDir dir c = c{cmdDir = Just dir}

-- | Add or override environment variables, like @K=v cmd@; the rest of the environment stays.
withEnv :: [(Text, Text)] -> Cmd -> Cmd
withEnv vars c = c{cmdEnv = cmdEnv c ++ vars}

{- | Discard stderr, and stdout too where nothing reads it ('run',
'succeeds', 'exitCode'), like @cmd >/dev/null 2>&1@.
-}
quiet :: Cmd -> Cmd
quiet c = c{cmdQuiet = True}

-- | Stop the command after this many seconds; that is a t'Cantrip.Core.ScriptError'.
withTimeout :: Double -> Cmd -> Cmd
withTimeout seconds c = c{cmdTimeout = Just seconds}

{- | On failure, include the last lines of the command's stderr in the
message. Off by default because output is where secrets tend to be.
Stderr still shows as it happens (unless 'quiet').
-}
errorTail :: Cmd -> Cmd
errorTail c = c{cmdErrorTail = True}

-- | Run with the script's stdout and stderr, like a plain shell line. Fails if the command fails.
run :: Cmd -> IO ()
run c = checked c =<< execute c (if cmdQuiet c then nullStream else inherit) return

-- | Stdout as 'Text', like @$(cmd)@: UTF-8 (invalid bytes become U+FFFD), trailing newlines removed.
capture :: Cmd -> IO Text
capture c = T.dropWhileEnd (== '\n') . decodeUtf8Lenient <$> captureBytes c

-- | Stdout split into lines.
captureLines :: Cmd -> IO [Text]
captureLines c = T.lines <$> capture c

-- | Stdout decoded as JSON, into a 'Data.Aeson.Value' or any 'FromJSON' type.
captureJson :: (FromJSON a) => Cmd -> IO a
captureJson c = do
    out <- captureLazy c
    either (\e -> failWith ("bad JSON from " <> programOf c <> ": " <> T.pack (take 200 e))) return (eitherDecode out)

{- | Handle each line of stdout as the command produces it, like
@cmd | while read -r line@. Fails at the end if the command fails.
-}
forLines :: Cmd -> (Text -> IO ()) -> IO ()
forLines c each = checked c =<< execute c createPipe stream
  where
    stream h = do
        out <- BL.hGetContents h
        mapM_ (each . decodeUtf8Lenient . BL.toStrict) (BL8.lines out)

-- | Whether the command exits 0, like @if cmd; then@. A non-zero exit is an answer, not a failure.
succeeds :: Cmd -> IO Bool
succeeds c = (== 0) <$> exitCode c

-- | The exit status (a signal @n@ reads as @128 + n@, as in the shell). Never fails on a non-zero exit.
exitCode :: Cmd -> IO Int
exitCode c = do
    ((codes, _), ()) <- execute c (if cmdQuiet c then nullStream else inherit) return
    return (maybe 0 (status . snd) (firstFailure codes))
  where
    status (ExitFailure n) | n < 0 = 128 - n
    status (ExitFailure n) = n
    status ExitSuccess = 0

-- | Print a line to stdout as UTF-8, like @echo@.
echo :: Text -> IO ()
echo t = BS.hPut stdout (encodeUtf8 (t <> "\n"))

-- | 'show' as 'Text', for numbers in messages: @echo ("found " <> tshow n)@.
tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Stdout exactly as the command wrote it, for binary output. Fails if the command fails.
captureBytes :: Cmd -> IO BS.ByteString
captureBytes c = BL.toStrict <$> captureLazy c

captureLazy :: Cmd -> IO BL.ByteString
captureLazy c = do
    (outcome, out) <- execute c byteStringOutput atomically
    checked c (outcome, ())
    return out

-- | Exit codes per stage (with the stage index) and the stderr tail, if kept.
type Outcome = ([(Int, ExitCode)], Maybe Text)

checked :: Cmd -> (Outcome, a) -> IO a
checked c ((codes, tailText), a) = case firstFailure codes of
    Nothing -> return a
    Just (i, code) -> failWith (describe (cmdStages c !! i) <> " (" <> status code <> ")" <> maybe "" ("\n" <>) tailText)
  where
    describe (Exec p _) = "command failed: " <> p
    describe (ShellLine l) = "shell command failed: " <> T.takeWhile (/= ' ') (T.strip l) <> " ..."
    status (ExitFailure n) | n < 0 = "killed by signal " <> tshow (negate n)
    status (ExitFailure n) = "exit " <> tshow n
    status ExitSuccess = "exit 0"

-- | pipefail, except that SIGPIPE in a stage before the last is how @head@ and friends stop a producer.
firstFailure :: [(Int, ExitCode)] -> Maybe (Int, ExitCode)
firstFailure codes = listToMaybe [(i, code) | (i, code) <- codes, failed i code]
  where
    lastIndex = length codes - 1
    failed _ ExitSuccess = False
    failed i (ExitFailure n) = not (n == -13 && i < lastIndex)

{- | Start every stage, pipe each one's stdout into the next, run the
action on the last stage's stdout, then wait for all of them.
-}
execute :: Cmd -> StreamSpec 'STOutput o -> (o -> IO a) -> IO (Outcome, a)
execute c lastOut action = do
    trace
    hFlush stdout >> hFlush stderr
    environment <- if null (cmdEnv c) then return Nothing else Just . merged <$> getEnvironment
    tailRef <- newIORef BS.empty
    let configure :: ProcessConfig () () () -> ProcessConfig () () ()
        configure =
            maybe id (setWorkingDir . T.unpack) (cmdDir c)
                . maybe id setEnv environment
                . (if cmdQuiet c && not (cmdErrorTail c) then setStderr nullStream else id)
        base (Exec p as) = proc (T.unpack p) (map T.unpack as)
        base (ShellLine l) = proc "sh" ["-c", T.unpack l]
        stdinFor :: Maybe Handle -> ProcessConfig () () () -> ProcessConfig () () ()
        stdinFor (Just h) = setStdin (useHandleClose h)
        stdinFor Nothing = maybe id (setStdin . byteStringInput . BL.fromStrict) (cmdInput c)
        withStage cfg k
            | cmdErrorTail c = withProcessTerm (setStderr createPipe cfg) $ \p -> do
                done <- tee (cmdQuiet c) tailRef (getStderr p)
                k (getStdout p) (waitExitCode p `finally` takeMVar done)
            | otherwise = withProcessTerm cfg $ \p -> k (getStdout p) (waitExitCode p)
        go _ _ [] = error "Cantrip.Shell: a command with no stages"
        go i input [s] = withStage (setStdout lastOut (stdinFor input (configure (base s)))) $ \out wait -> do
            a <- action out
            code <- wait
            return ([(i, code)], a)
        go i input (s : rest) = withStage (setStdout createPipe (stdinFor input (configure (base s)))) $ \out wait -> do
            (codes, a) <- go (i + 1) (Just out) rest
            code <- wait
            return ((i, code) : codes, a)
        start = go 0 Nothing (cmdStages c) `catch` notFound
    result <- case cmdTimeout c of
        Nothing -> Just <$> start
        Just seconds -> Timeout.timeout (round (seconds * 1000000)) start
    case result of
        Nothing -> failWith ("command timed out after " <> tshow (fromMaybe 0 (cmdTimeout c)) <> " s: " <> programOf c)
        Just (codes, a) -> do
            kept <- readIORef tailRef
            let tailText = if cmdErrorTail c && not (BS.null kept) then Just (lastLines kept) else Nothing
            return ((codes, tailText), a)
  where
    merged current = [(k, v) | (k, v) <- current, isNothing (lookup k overrides)] ++ overrides
    overrides = [(T.unpack k, T.unpack v) | (k, v) <- cmdEnv c]
    trace = do
        flag <- lookupEnv "CANTRIP_TRACE"
        unless (maybe True (`elem` ["", "0"]) flag) $
            BS.hPut stderr (encodeUtf8 ("+ " <> showCmd c <> "\n"))
    notFound :: IOException -> IO a
    notFound e
        | isDoesNotExistError e = do
            dirOk <- maybe (return True) (doesDirectoryExist . T.unpack) (cmdDir c)
            missing <- forM [p | Exec p _ <- cmdStages c] $ \p -> (,) p <$> findable p
            case (dirOk, [p | (p, False) <- missing]) of
                (False, _) -> failWith ("no such directory: " <> fromMaybe "" (cmdDir c))
                (_, p : _) -> failWith ("command not found: " <> p)
                _ -> throwIO e
        | otherwise = throwIO e
    findable p
        | "/" `T.isInfixOf` p = doesFileExist (T.unpack p)
        | otherwise = isJust <$> findExecutable (T.unpack p)

-- | Copy a stage's stderr through (unless quiet), keeping the last 4 KB.
tee :: Bool -> IORef BS.ByteString -> Handle -> IO (MVar ())
tee silent ref h = do
    done <- newEmptyMVar
    let loop = do
            chunk <- BS.hGetSome h 4096
            unless (BS.null chunk) $ do
                unless silent (BS.hPut stderr chunk)
                atomicModifyIORef' ref (\kept -> (BS.takeEnd 4096 (kept <> chunk), ()))
                loop
    _ <- forkIO (loop `catch` ignore `finally` putMVar done ())
    return done
  where
    ignore :: IOException -> IO ()
    ignore _ = return ()

lastLines :: BS.ByteString -> Text
lastLines = T.intercalate "\n" . reverse . take 20 . reverse . T.lines . T.dropWhileEnd (== '\n') . decodeUtf8Lenient

programOf :: Cmd -> Text
programOf c = case cmdStages c of
    Exec p _ : _ -> p
    ShellLine l : _ -> T.takeWhile (/= ' ') (T.strip l)
    [] -> ""

{- | The command as a shell line, quoted where needed:
@cd dir && K=v git log --format='%s' | wc -l@. What @CANTRIP_TRACE@ prints.
-}
showCmd :: Cmd -> Text
showCmd c =
    T.unwords $
        maybe [] (\d -> ["cd", quote d, "&&"]) (cmdDir c)
            ++ [k <> "=" <> quote v | (k, v) <- cmdEnv c]
            ++ [T.intercalate " | " (map stage (cmdStages c))]
            ++ maybe [] (const ["<<<", "…"]) (cmdInput c)
  where
    stage (Exec p as) = T.unwords (map quote (p : as))
    stage (ShellLine l) = "sh -c " <> quote l
    quote w
        | not (T.null w) && T.all safe w = w
        | otherwise = "'" <> T.replace "'" "'\\''" w <> "'"
    safe ch = ch `elem` ("_@%+=:,./-" :: String) || isAsciiLower ch || isAsciiUpper ch || isDigit ch
