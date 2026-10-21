{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

import Cantrip
import Cantrip.Shell.Syntax (Part (..), parseCommandLine)
import Control.Applicative ((<|>))
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (ErrorCall, SomeException, bracket, displayException, evaluate, try)
import Control.Monad (replicateM_)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as T
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.Directory (
    canonicalizePath,
    createDirectory,
    createDirectoryLink,
    createFileLink,
    doesDirectoryExist,
    getCurrentDirectory,
    getTemporaryDirectory,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
    setCurrentDirectory,
    setModificationTime,
 )
import System.Environment (getArgs, getEnvironment, getExecutablePath)
import qualified System.Environment as Env
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, openTempFile)
import System.Posix.Files (fileMode, getFileStatus)
import qualified System.Process.Typed as P
import System.Timeout (timeout)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("cli" : mode : _) -> cliFixture mode
        _ -> tests

-- | The test binary re-runs itself as a script to observe real stdout and exit codes.
cliFixture :: String -> IO ()
cliFixture "plain-fail" = script (\_ -> failWith "café")
cliFixture "ordered" = script $ \_ -> putStrLn "1" >> run [sh|echo 2|] >> echo "3 ünïcode"
cliFixture "noisy" = jsonScript $ \_ -> putStrLn "debug" >> run (cmd "echo" ["child"]) >> return Null
cliFixture "cmd-fail" = jsonScript $ \_ -> run (cmd "sh" ["-c", "exit 3", "--", "--token=hunter2"]) >> return Null
cliFixture "shell-fail" = jsonScript $ \_ -> capture (shell "echo secret-output; exit 4") >> return Null
cliFixture "typed-fail" = jsonScript $ \_ -> P.runProcess_ (P.proc "sh" ["-c", "exit 5", "--", "--token=hunter2"]) >> return Null
cliFixture "quiet" = script $ \_ -> run (quiet (shell "echo out; echo err >&2"))
cliFixture "tail" = jsonScript $ \_ -> run (errorTail (shell "echo first >&2; echo oops >&2; exit 3")) >> return Null
cliFixture "trace" = script $ \_ -> run (cmd "true" ["a b", "c"])
cliFixture "args" = jsonScript $ \argv -> do
    args <- parseArgs ["dry-run", "retries=N", "FILE"] (drop 2 argv)
    return (object ["dry" .= switch "dry-run" args, "file" .= positional "FILE" args])
cliFixture mode = jsonScript $ \_ -> case mode of
    "object" -> return (object ["buckets" .= [1 :: Int]])
    "null" -> return Null
    "scalar" -> return (Number 7)
    "fail" -> failWith "nope"
    _ -> ioError (userError "boom")

tests :: IO ()
tests = do
    fixture <- requireJson "{\"name\":\"cantrip\",\"count\":3,\"id\":9007199254740993}"
    check "str reads strings" (str "name" fixture == Just "cantrip")
    check "num reads numbers" (num "count" fixture == Just 3)
    check "int preserves integers" (int "id" fixture == Just 9007199254740993)
    hostile <- requireJson "{\"big\":1e1000000000,\"neg\":-1e1000000000,\"nan\":\"NaN\",\"half\":1.5,\"u64\":18446744073709551615,\"over\":18446744073709551616}"
    bigInt <- timeout 2000000 (evaluate (int "big" hostile))
    check "int rejects huge exponents quickly" (bigInt == Just Nothing)
    negInt <- timeout 2000000 (evaluate (int "neg" hostile))
    check "int rejects huge negative numbers quickly" (negInt == Just Nothing)
    bigNum <- timeout 2000000 (evaluate (num "big" hostile))
    check "num rejects values beyond Double" (bigNum == Just Nothing)
    check "num rejects NaN strings" (isNothing (num "nan" hostile))
    check "int rejects fractions" (isNothing (int "half" hostile))
    check "int accepts unsigned 64-bit" (int "u64" hostile == Just 18446744073709551615)
    check "int rejects beyond 64 bits" (isNothing (int "over" hostile))
    check
        "jwtClaim reads nested claims"
        (jwtClaim access "claim" "field" "missing" == "value")
    check
        "jwtClaim falls back on malformed input"
        (jwtClaim "not-a-jwt" "claim" "field" "missing" == "missing")
    tmp <- getTemporaryDirectory
    (path, handle) <- openTempFile tmp "cantrip-hs-test"
    hClose handle
    removeFile path
    let target = T.pack path
    atomicWriteFile target "hello" 0o600
    check "atomicWriteFile writes bytes" . (== "hello") =<< BS.readFile path
    removeFile path
    let lock = path ++ ".lock"
    withLockDir (T.pack lock) (return ())
    check "withLockDir removes lock" . not =<< doesDirectoryExist lock
    createDirectory lock
    old <- addUTCTime (-60) <$> getCurrentTime
    setModificationTime lock old
    took <- withLockDir (T.pack lock) (return True)
    check "withLockDir takes over a stale lock" took
    check "withLockDir releases a taken-over lock" . not =<< doesDirectoryExist lock
    noParent <- timeout 5000000 (try (withLockDir (target <> ".missing/x.lock") (return ())))
    check "withLockDir fails fast without a parent directory" $ case noParent of
        Just (Left (ScriptError reason)) -> "cannot create lock" `T.isInfixOf` reason
        _ -> False
    contended <- contention (target <> ".contended.lock")
    check "withLockDir excludes concurrent holders" contended
    let dir = path ++ ".dir"
    createDirectory dir
    createDirectory (dir ++ "/target")
    intoDir <- try (atomicWriteFile (T.pack dir <> "/target") "x" 0o600) :: IO (Either SomeException ())
    leftover <- listDirectory dir
    check "atomicWriteFile cleans up its temp file on failure" (either (const True) (const False) intoDir && leftover == ["target"])
    removeDirectoryRecursive dir
    check "parseIso8601Ms parses Z timestamps" (parseIso8601Ms "2026-09-22T12:00:00Z" == Just 1790078400000)
    check "parseIso8601Ms parses offsets" (parseIso8601Ms "2026-09-22T14:00:00+02:00" == Just 1790078400000)
    check "parseIso8601Ms parses fractionals" (parseIso8601Ms "2026-09-22T12:00:00.500Z" == Just 1790078400500)
    check "parseIso8601Ms rejects garbage" (isNothing (parseIso8601Ms "not-a-date"))
    check "formatIso8601Ms round-trips" (parseIso8601Ms (formatIso8601Ms 1790078400000) == Just 1790078400000)
    check "formatIso8601Ms keeps millis" (formatIso8601Ms 1790078400500 == "2026-09-22T12:00:00.500Z")
    badUrl <- orNothing (parseRequest "not a URL" >>= http)
    check "orNothing swallows malformed URLs" (isNothing badUrl)
    refused <- try (http (setRequestHeader "Authorization" ["Bearer secret-token"] (parseRequest_ "http://127.0.0.1:1/")))
    check "http turns transport failures into ScriptError naming the host" $ case refused of
        Left (ScriptError reason) -> "127.0.0.1" `T.isInfixOf` reason && not ("secret-token" `T.isInfixOf` reason)
        Right _ -> False
    httpChecks
    argChecks
    shellChecks
    fsChecks
    encodingChecks
    present <- expect "absent" (Just (1 :: Int))
    absent <- try (expect "absent" (Nothing :: Maybe Int))
    check "expect unwraps Just and fails on Nothing" $ case absent of
        Left (ScriptError reason) -> present == 1 && reason == "absent"
        Right _ -> False
    check "ScriptError displays its reason" (displayException (ScriptError "nope") == "nope")
    cabal <- readFile "cantrip-hs.cabal"
    check
        "userAgent carries the package version"
        (any (\l -> "version:" `isPrefixOf` l && C8.unpack (BS.drop 11 userAgent) == last (words l)) (lines cabal))
    nested <- requireJson "{\"a\":{\"b\":{\"c\":1}},\"xs\":[10,20],\"s\":\"12.5\"}"
    check "at reads nested paths" (at ["a", "b", "c"] nested == Just (Number 1))
    check "at reads array indices" (at ["xs", "1"] nested == Just (Number 20))
    check "at misses gracefully" (isNothing (at ["a", "x"] nested))
    check "str reads strings" (str "s" nested == Just "12.5")
    check "str skips numbers" (isNothing (str "xs" nested))
    check "num coerces numeric strings" (num "s" nested == Just 12.5)
    check "num rejects non-numbers" (isNothing (num "a" nested) && isNothing (num "xs" nested))
    check "int stays exact" (int "id" fixture == Just 9007199254740993)
    check "obj matches objects only" (case obj "a" nested of Just (Object _) -> True; _ -> False)
    check "arr matches arrays only" (case arr "xs" nested of Just [_, _] -> True; _ -> False)
    let seeded = upsert "k" (String "v") (object ["keep" .= (1 :: Int)])
    check "upsert inserts" (str "k" seeded == Just "v" && int "keep" seeded == Just 1)
    let merged = upsert "cfg" (object ["x" .= (1 :: Int)]) (object ["cfg" .= object ["y" .= (2 :: Int)]])
    check "upsert deep-merges objects" (at ["cfg", "x"] merged == Just (Number 1) && at ["cfg", "y"] merged == Just (Number 2))
    check "merge replaces non-objects" (at ["a"] (merge (object ["a" .= [1 :: Int]]) (object ["a" .= [2 :: Int]])) == Just (toJSON [2 :: Int]))
    atomicWriteFile target "{}" 0o600
    modifyJsonFile target 0o600 (return . upsert "a" (String "2"))
    writtenBytes <- BS.readFile path
    written <- requireJson writtenBytes
    check "modifyJsonFile writes under lock" (str "a" written == Just "2")
    check "modifyJsonFile ends the file with a newline" ("\n" `BS.isSuffixOf` writtenBytes)
    boom <- try (modifyJsonFile target 0o600 (\_ -> failWith "nope"))
    unchanged <- requireJson =<< BS.readFile path
    check
        "modifyJsonFile keeps the file on a failing update"
        (case boom of Left (ScriptError _) -> str "a" unchanged == Just "2"; Right _ -> False)
    removeFile path
    check "envOr falls back when unset" . (== "def") =<< envOr "CANTRIP_TEST_UNSET_VAR" "def"
    Env.setEnv "CANTRIP_TEST_SET_VAR" "set"
    check "envOr reads the environment" . (== "set") =<< envOr "CANTRIP_TEST_SET_VAR" "def"
    self <- getExecutablePath
    environment <- getEnvironment
    let cli mode = P.readProcess (P.proc self ["cli", mode])
        cliArgs extra = P.readProcess (P.proc self (["cli", "args"] ++ extra))
        cliWith vars mode = P.readProcess (P.setEnv (vars ++ environment) (P.proc self ["cli", mode]))
    cliCheck "parseArgs reads switches and positionals" (cliArgs ["--dry-run", "a.json"]) ExitSuccess "{\"dry\":true,\"file\":\"a.json\",\"ok\":true}"
    (helpCode, helpOut, helpErr) <- cliArgs ["--help"]
    check
        "parseArgs --help prints the generated usage (stderr under jsonScript)"
        (helpCode == ExitSuccess && helpOut == "" && helpErr == "usage: cantrip-hs-test [--dry-run] [--retries N] FILE\n")
    cliCheck "parseArgs errors follow jsonScript" (cliArgs ["--nope"]) (ExitFailure 1) "{\"ok\":false,\"reason\":\"unknown option: --nope\\nusage: cantrip-hs-test [--dry-run] [--retries N] FILE\"}"
    cliCheck "jsonScript marks objects ok" (cli "object") ExitSuccess "{\"buckets\":[1],\"ok\":true}"
    cliCheck "jsonScript prints ok for Null" (cli "null") ExitSuccess "{\"ok\":true}"
    cliCheck "jsonScript wraps scalars" (cli "scalar") ExitSuccess "{\"ok\":true,\"result\":7}"
    cliCheck "jsonScript renders ScriptError" (cli "fail") (ExitFailure 1) "{\"ok\":false,\"reason\":\"nope\"}"
    cliCheck "jsonScript renders other exceptions" (cli "io") (ExitFailure 1) "{\"ok\":false,\"reason\":\"user error (boom)\"}"
    (plainCode, _, errBytes) <- cliWith [("LC_ALL", "C")] "plain-fail"
    check "script writes UTF-8 errors in a C locale" (plainCode == ExitFailure 1 && errBytes == BL.fromStrict (encodeUtf8 "error: café\n"))
    cliCheck "script output stays in order and UTF-8 in a C locale" (cliWith [("LC_ALL", "C")] "ordered") ExitSuccess (BL.fromStrict (encodeUtf8 "1\n2\n3 ünïcode"))
    (_, noisyOut, noisyErr) <- cli "noisy"
    check "jsonScript sends other stdout, commands included, to stderr" (noisyOut == "{\"ok\":true}\n" && noisyErr == "debug\nchild\n")
    cliCheck "a failed command is reported without its arguments" (cli "cmd-fail") (ExitFailure 1) "{\"ok\":false,\"reason\":\"command failed: sh (exit 3)\"}"
    cliCheck "a failed shell command is reported without its output" (cli "shell-fail") (ExitFailure 1) "{\"ok\":false,\"reason\":\"shell command failed: echo ... (exit 4)\"}"
    cliCheck "typed-process failures are reported the same way" (cli "typed-fail") (ExitFailure 1) "{\"ok\":false,\"reason\":\"command failed: sh (exit 5)\"}"
    quietRun <- cli "quiet"
    check "quiet discards stdout and stderr" (quietRun == (ExitSuccess, "", ""))
    (tailCode, tailOut, tailErr) <- cli "tail"
    check
        "errorTail adds the end of stderr to the reason and still shows it"
        ( tailCode == ExitFailure 1
            && tailOut == "{\"ok\":false,\"reason\":\"shell command failed: echo ... (exit 3)\\nfirst\\noops\"}\n"
            && tailErr == "first\noops\n"
        )
    traced <- cliWith [("CANTRIP_TRACE", "1")] "trace"
    check "CANTRIP_TRACE prints each command, quoted" (traced == (ExitSuccess, "", "+ true 'a b' c\n"))
    untraced <- cliWith [("CANTRIP_TRACE", "0")] "trace"
    check "CANTRIP_TRACE=0 prints nothing" (untraced == (ExitSuccess, "", ""))
  where
    access = "header.eyJjbGFpbSI6eyJmaWVsZCI6InZhbHVlIn19.signature"

-- | Four threads take the same lock repeatedly; none may find another inside.
contention :: Text -> IO Bool
contention lock = do
    inside <- newIORef False
    ok <- newIORef True
    done <- newEmptyMVar
    let critical = do
            busy <- atomicModifyIORef' inside (True,)
            if busy then writeIORef ok False else threadDelay 2000 >> writeIORef inside False
        worker = do
            r <- try (replicateM_ 5 (withLockDir lock critical)) :: IO (Either SomeException ())
            either (const (writeIORef ok False)) return r
            putMVar done ()
    replicateM_ 4 (forkIO worker)
    replicateM_ 4 (takeMVar done)
    readIORef ok

argChecks :: IO ()
argChecks = do
    let spec = ["dry-run", "v", "retries=", "name=", "IN", "REST..."]
        parse = parseArgsWith "usage: t" spec
    a <- parse ["in.json", "--dry-run", "--retries", "3", "-v", "--name=x", "--name", "y", "-", "--", "--dry-run"]
    check "parseArgs keeps positionals in order, -- ends options" (positionals a == ["in.json", "-", "--dry-run"])
    check "positional reads a required positional by name" (positional "IN" a == "in.json")
    check "usageText carries the override" (usageText a == "usage: t")
    check "parseArgs reads switches, one dash or two" (switch "dry-run" a && switch "v" a)
    check "parseArgs: the last repeated option wins" (option "name" a == Just "y")
    retries <- readOption "retries" a
    check "readOption parses numbers" (retries == Just (3 :: Int))
    none <- parse ["in.json"]
    check "absent switches and options" (not (switch "dry-run" none) && isNothing (option "name" none))
    let rejects label argv needle = do
            r <- try (parse argv)
            check label $ case r of
                Left (ScriptError reason) -> needle `T.isInfixOf` reason && "usage: t" `T.isInfixOf` reason
                Right _ -> False
    rejects "parseArgs rejects unknown options" ["--nope"] "unknown option: --nope"
    rejects "parseArgs rejects a missing value" ["x", "--retries"] "--retries needs a value"
    rejects "parseArgs rejects a value on a switch" ["x", "--dry-run=yes"] "--dry-run takes no value"
    rejects "parseArgs rejects missing positionals" [] "missing argument: IN"
    strict <- try (parseArgsWith "usage: t" ["FILE"] ["a", "b"])
    check "parseArgs rejects extra positionals without NAME..." $ case strict of
        Left (ScriptError reason) -> "unexpected argument: b" `T.isInfixOf` reason
        Right _ -> False
    bad <- parse ["x", "--retries", "many"]
    badRead <- try (readOption "retries" bad :: IO (Maybe Int))
    check "readOption rejects unparsable values" $ case badRead of
        Left (ScriptError reason) -> reason == "--retries: invalid value: many"
        Right _ -> False
    undeclared <- try (evaluate (switch "dryrun" a)) :: IO (Either ErrorCall Bool)
    check "asking for an undeclared name is a loud bug" (either (const True) (const False) undeclared)
    wrongKind <- try (evaluate (option "dry-run" a)) :: IO (Either ErrorCall (Maybe Text))
    check "asking for a switch as an option is a loud bug" (either (const True) (const False) wrongKind)
    notPositional <- try (evaluate (T.length (positional "REST" a))) :: IO (Either ErrorCall Int)
    check "positional on an undeclared name is a loud bug" (either (const True) (const False) notPositional)
    misordered <- try (parseArgsWith "u" ["REST...", "IN"] [] >>= evaluate . length . positionals) :: IO (Either ErrorCall Int)
    check "a positional after NAME... is a loud bug" (either (const True) (const False) misordered)

-- | A ScriptError whose reason satisfies the predicate.
failsWith :: String -> (Text -> Bool) -> IO a -> IO ()
failsWith label ok action = do
    r <- try action
    check label $ case r of
        Left (ScriptError reason) -> ok reason
        Right _ -> False

shellChecks :: IO ()
shellChecks = do
    let n = 3 :: Int
        v = "V" :: Text
        xs = ["p", "q"] :: [Text]
        none = Nothing :: Maybe Text
        some = Just "z" :: Maybe Text
        hostile = "has space; rm -rf / $(id)" :: Text
    check "[sh|...|] splits words, keeps quotes, spreads lists, drops Nothing" (showCmd [sh|git log -n ${n} 'a b' "x ${v}y" ${xs} ${none} ${some}|] == "git log -n 3 'a b' 'x Vy' p q z")
    check "[sh|...|] treats a backslash as an escape" (showCmd [sh|echo a\ b \$x|] == "echo 'a b' '$x'")
    echoed <- capture [sh|printf %s ${hostile}|]
    check "[sh|...|] passes a variable as exactly one argument" (echoed == hostile)
    emptyArg <- capture [sh|printf %s:%s: '' x|]
    check "[sh|...|] keeps an empty quoted argument" (emptyArg == ":x:")
    sorted <- capture [sh|printf 'b\na\n' | sort|]
    check "[sh|...|] pipes stages" (sorted == "a\nb")
    check "parseCommandLine reads mixed words" (parseCommandLine "a --out=${dir}/x" == Right [[[Lit "a"], [Lit "--out=", Var "dir", Lit "/x"]]])
    let rejects input = isLeft (parseCommandLine input)
    check "parseCommandLine rejects broken syntax" (all rejects ["", "a | | b", "| a", "a |", "'open", "\"open", "${open", "${not a name}", "${Upper}", "a \\"])
    listed <- capture (cmd "printf" ["%s", "a b"])
    check "cmd passes arguments as they are" (listed == "a b")
    viaShell <- capture (shell "echo $((1 + 2))")
    check "shell runs a line through sh" (viaShell == "3")
    piped <- capture (cmd "printf" ["b\na\n"] |> cmd "sort" [])
    check "|> pipes commands" (piped == "a\nb")
    headed <- timeout 5000000 (capture (cmd "yes" [] |> cmd "head" ["-n", "1"]))
    check "an early stage stopped by SIGPIPE is not a failure" (headed == Just "y")
    failsWith "a failing early stage fails the pipeline" (== "command failed: false (exit 1)") (capture (cmd "false" [] |> cmd "cat" []))
    check "succeeds reads exit 0" =<< succeeds (cmd "true" [])
    check "succeeds reads a non-zero exit" . not =<< succeeds (cmd "false" [])
    check "exitCode returns the status" . (== 7) =<< exitCode (shell "exit 7")
    check "exitCode reads a signal as 128 + n" . (== 137) =<< exitCode (shell "kill -9 $$")
    failsWith "run reports a signal" (== "shell command failed: kill ... (killed by signal 9)") (run (shell "kill -9 $$"))
    check "captureLines splits lines" . (== ["a", "b"]) =<< captureLines (shell "printf 'a\\nb\\n'")
    check "captureLines of no output is empty" . null =<< captureLines (cmd "true" [])
    decoded <- captureJson (cmd "echo" ["{\"a\":1}"])
    check "captureJson decodes stdout" (int "a" decoded == Just 1)
    failsWith "captureJson names the command on bad JSON" ("bad JSON from echo:" `T.isPrefixOf`) (captureJson (cmd "echo" ["nope"]) :: IO Value)
    seen <- newIORef []
    started <- getCurrentTime
    firstAt <- newIORef Nothing
    forLines (shell "echo first; sleep 1; echo second") $ \line -> do
        now <- getCurrentTime
        atomicModifyIORef' firstAt (\t -> (t <|> Just now, ()))
        atomicModifyIORef' seen (\ls -> (ls ++ [line], ()))
    lines' <- readIORef seen
    early <- maybe False (\t -> diffUTCTime t started < 0.8) <$> readIORef firstAt
    check "forLines handles lines while the command still runs" (lines' == ["first", "second"] && early)
    fed <- capture (cmd "cat" [] <<< "héllo")
    check "<<< feeds stdin as UTF-8" (fed == "héllo")
    let binary = BS.pack [0, 255, 10, 13, 128, 0]
    echoedBytes <- captureBytes (withStdinBytes binary (cmd "cat" []))
    check "withStdinBytes and captureBytes pass binary data unchanged" (echoedBytes == binary)
    let big = T.replicate 1000000 "abcde"
    bigEcho <- timeout 10000000 (capture (cmd "cat" [] <<< big))
    check "feeding 5 MB while reading stdout does not deadlock" (bigEcho == Just big)
    withTempDir $ \dir -> do
        here <- capture (inDir dir (cmd "pwd" []))
        real <- canonicalizePath (T.unpack dir)
        check "inDir runs in another directory" (here == T.pack real)
    failsWith "inDir names a missing directory" (== "no such directory: /nonexistent-cantrip-dir") (run (inDir "/nonexistent-cantrip-dir" (cmd "true" [])))
    Env.setEnv "CANTRIP_TEST_KEEP" "kept"
    envd <- capture (withEnv [("CANTRIP_X", "1 2")] (shell "printf '%s|%s' \"$CANTRIP_X\" \"$CANTRIP_TEST_KEEP\""))
    check "withEnv adds variables and keeps the rest" (envd == "1 2|kept")
    overridden <- capture (withEnv [("CANTRIP_TEST_KEEP", "new")] (shell "printf %s \"$CANTRIP_TEST_KEEP\""))
    check "withEnv overrides a variable" (overridden == "new")
    before <- getCurrentTime
    failsWith "withTimeout stops a slow command" (== "command timed out after 0.3 s: sleep") (run (withTimeout 0.3 (cmd "sleep" ["5"])))
    after <- getCurrentTime
    check "withTimeout stops it promptly" (diffUTCTime after before < 3)
    failsWith "a missing program is named" (== "command not found: no-such-cantrip-command") (run (cmd "no-such-cantrip-command" []))
    failsWith "errorTail adds the end of stderr" (== "shell command failed: echo ... (exit 2)\noops") (run (quiet (errorTail (shell "echo oops >&2; exit 2"))))
    failsWith "without errorTail the reason has no output" (== "shell command failed: echo ... (exit 2)") (run (quiet (shell "echo oops >&2; exit 2")))
    check
        "showCmd renders directory, environment, pipes and input"
        (showCmd (inDir "/tmp x" (withEnv [("K", "a b")] (cmd "git" ["log", "--format=%s"] |> shell "wc -l")) <<< "x") == "cd '/tmp x' && K='a b' git log --format=%s | sh -c 'wc -l' <<< …")

encodingChecks :: IO ()
encodingChecks = do
    let bytes = BS.pack [0, 1, 171, 205, 239, 255]
    check "toHex writes lowercase hex" (toHex bytes == "0001abcdefff")
    check "fromHex reads either case and skips whitespace" (fromHex "0001ABcd ef\nff" == Just bytes)
    check "fromHex rejects odd lengths and non-hex" (isNothing (fromHex "abc") && isNothing (fromHex "zz") && isNothing (fromHex "é0"))
    check "toBase64 writes padded base64" (toBase64 "hi!?" == "aGkhPw==")
    check "fromBase64 round-trips and skips line wrapping" (fromBase64 (T.intercalate "\n" (T.chunksOf 4 (toBase64 bytes))) == Just bytes)
    check "fromBase64 rejects garbage" (isNothing (fromBase64 "not base64!"))
    check "fromUtf8 decodes valid UTF-8" (fromUtf8 (encodeUtf8 "héllo") == Just "héllo")
    check "fromUtf8 rejects invalid bytes" (isNothing (fromUtf8 (BS.pack [104, 255])))
    check "decodeUtf8Lenient replaces invalid bytes" (decodeUtf8Lenient (BS.pack [104, 255]) == "h\xfffd")

fsChecks :: IO ()
fsChecks = do
    kept <- withTempDir $ \dir -> do
        status <- getFileStatus (T.unpack dir)
        check "withTempDir is private" (fileMode status .&. 0o777 == 0o700)
        mapM_ (mkdirP . (dir </>)) ["a/sub", "a/.git"]
        mapM_ (\f -> writeText (dir </> f) "abc") ["top.hs", "a/b.hs", "a/c.txt", "a/.hidden.hs", "a/sub/d.hs", "a/.git/e.hs"]
        createFileLink "b.hs" (T.unpack (dir </> "a/link.hs"))
        createDirectoryLink "sub" (T.unpack (dir </> "a/loop"))
        original <- getCurrentDirectory
        bracket (cd dir) (const (setCurrentDirectory original)) $ \_ -> do
            here <- pwd
            real <- canonicalizePath (T.unpack dir)
            check "cd and pwd change and read the directory" (here == T.pack real)
            let globs pat expected = glob pat >>= \got -> check ("glob " ++ T.unpack pat) (got == expected)
            globs "a/*.hs" ["a/b.hs", "a/link.hs"]
            globs "a/**/*.hs" ["a/b.hs", "a/link.hs", "a/sub/d.hs"]
            globs "**/d.hs" ["a/sub/d.hs"]
            globs "a/.*.hs" ["a/.hidden.hs"]
            globs "a/?.txt" ["a/c.txt"]
            globs "*.hs" ["top.hs"]
            globs "nope/*" []
            globs "top.hs" ["top.hs"]
        absolute <- glob (dir </> "a/*.txt")
        check "glob takes absolute patterns" (absolute == [dir </> "a/c.txt"])
        entries <- listDir (dir </> "a")
        check "listDir lists everything, sorted" (map entryName entries == [".git", ".hidden.hs", "b.hs", "c.txt", "link.hs", "loop", "sub"])
        let named x = case [e | e <- entries, entryName e == x] of
                e : _ -> e
                [] -> error ("no entry " ++ T.unpack x)
        check "listDir tells files, directories and symlinks apart" (isFile (named "b.hs") && isDir (named "sub") && isSymlink (named "link.hs") && not (isFile (named "link.hs")))
        check "listDir gives sizes and paths" (entrySize (named "c.txt") == 3 && entryPath (named "c.txt") == dir </> "a" </> "c.txt")
        writeText (dir </> "t.txt") "héllo"
        appendText (dir </> "t.txt") "!\n"
        check "writeText and appendText write UTF-8" . (== "héllo!\n") =<< readText (dir </> "t.txt")
        failsWith "readText names an unreadable file" ("cannot read file: " `T.isPrefixOf`) (readText (dir </> "missing"))
        copy (dir </> "a") (dir </> "a2")
        check "copy copies a directory tree" =<< exists (dir </> "a2/sub/d.hs")
        copy (dir </> "top.hs") (dir </> "top2.hs")
        check "copy copies a file" . (== "abc") =<< readText (dir </> "top2.hs")
        move (dir </> "a2") (dir </> "a3")
        movedThere <- exists (dir </> "a3/b.hs")
        goneHere <- exists (dir </> "a2")
        check "move renames" (movedThere && not goneHere)
        remove (dir </> "a3")
        remove (dir </> "never-existed")
        check "remove deletes a tree, and a missing path is fine" . not =<< exists (dir </> "a3")
        return dir
    check "withTempDir removes the directory afterwards" . not =<< exists kept
    check "which finds a program" . isJust =<< which "sh"
    check "which misses quietly" . isNothing =<< which "no-such-cantrip-command"
    check "</> joins paths" ("a" </> "b" == "a/b")

-- | The success path, against a one-shot server on loopback.
httpChecks :: IO ()
httpChecks = do
    (url, seen) <- serveOnce "200 OK" "{\"ok\":true}"
    resp <- http =<< request url
    sent <- takeMVar seen
    check "http sends the default User-Agent" (("User-Agent: " <> userAgent) `BS.isInfixOf` sent)
    body <- expectJson resp
    check "expectJson decodes a 2xx body" (body == object ["ok" .= True])
    (url401, _) <- serveOnce "401 Unauthorized" "{}"
    denied <- http =<< request url401
    check "http returns non-2xx statuses as values" (getResponseStatusCode denied == 401)
    rejected <- try (expectJson denied :: IO Value)
    check "expectJson rejects non-2xx" $ case rejected of
        Left (ScriptError reason) -> reason == "http 401"
        Right _ -> False

serveOnce :: BS.ByteString -> BS.ByteString -> IO (Text, MVar BS.ByteString)
serveOnce status body = do
    sock <- socket AF_INET Stream defaultProtocol
    bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen sock 1
    port <- socketPort sock
    seen <- newEmptyMVar
    _ <- forkIO $ do
        (conn, _) <- accept sock
        raw <- readHead conn ""
        sendAll conn (BS.concat ["HTTP/1.1 ", status, "\r\nContent-Length: ", C8.pack (show (BS.length body)), "\r\nConnection: close\r\n\r\n", body])
        close conn
        close sock
        putMVar seen raw
    return (T.pack ("http://127.0.0.1:" ++ show port ++ "/"), seen)
  where
    readHead conn acc
        | "\r\n\r\n" `BS.isInfixOf` acc = return acc
        | otherwise = recv conn 4096 >>= \chunk -> if BS.null chunk then return acc else readHead conn (acc <> chunk)

requireJson :: BS.ByteString -> IO Value
requireJson input = case decode (BL.fromStrict input) of
    Just value -> return value
    Nothing -> putStrLn "test fixture is invalid JSON" >> exitFailure

cliCheck :: String -> IO (ExitCode, BL.ByteString, BL.ByteString) -> ExitCode -> BL.ByteString -> IO ()
cliCheck label action code out = do
    (actualCode, actualOut, _) <- action
    check label (actualCode == code && actualOut == out <> "\n")

check :: String -> Bool -> IO ()
check label ok = if ok then putStrLn ("ok: " ++ label) else putStrLn ("FAIL: " ++ label) >> exitFailure
