{-# LANGUAGE OverloadedStrings #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | Files and directories: the coreutils a script needs, atomic writes,
and mkdir locks (compatible with npm's @proper-lockfile@).

Paths are 'Text'. A file name that is not valid UTF-8 has its invalid
bytes replaced with U+FFFD, so it no longer names the same file.
-}
module Cantrip.Fs (
    -- * Paths
    (</>),
    cd,
    pwd,
    exists,
    which,

    -- * Reading and writing
    readText,
    writeText,
    appendText,
    atomicWriteFile,
    modifyJsonFile,

    -- * Directories
    Entry,
    entryName,
    entryPath,
    entrySize,
    entryModified,
    isFile,
    isDir,
    isSymlink,
    listDir,
    glob,
    mkdirP,
    copy,
    move,
    remove,
    withTempDir,

    -- * Locks
    withLockDir,
) where

import Cantrip.Core (failWith)
import Cantrip.Json (encodePretty, readJsonFile)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, SomeException, bracket, bracketOnError, catch, finally, throwIO, try)
import Control.Monad (filterM, forM, forM_, unless, when)
import Data.Aeson (Value)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf, nub, sort, tails)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import GHC.IO.Exception (IOErrorType (UnsupportedOperation))
import System.Directory (
    copyFileWithMetadata,
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesPathExist,
    findExecutable,
    getCurrentDirectory,
    getModificationTime,
    getTemporaryDirectory,
    listDirectory,
    removeDirectory,
    removeFile,
    removePathForcibly,
    renameFile,
    renamePath,
    setCurrentDirectory,
    setModificationTime,
 )
import qualified System.FilePath as FP
import System.IO (hClose, openTempFile)
import System.IO.Error (ioeGetErrorType, isAlreadyExistsError)
import qualified System.Posix.Directory as Posix
import System.Posix.Files (
    FileStatus,
    fileSize,
    getSymbolicLinkStatus,
    isDirectory,
    isRegularFile,
    isSymbolicLink,
    modificationTimeHiRes,
    setFileMode,
 )
import System.Posix.Types (FileMode)

infixr 5 </>

-- | Join two path parts with @/@, like @System.FilePath.\</\>@.
(</>) :: Text -> Text -> Text
a </> b = T.pack (T.unpack a FP.</> T.unpack b)

-- | Change the working directory of the script (and so of every command it runs from then on).
cd :: Text -> IO ()
cd = setCurrentDirectory . T.unpack

-- | The working directory.
pwd :: IO Text
pwd = T.pack <$> getCurrentDirectory

-- | Whether a file, directory, or anything else exists at the path.
exists :: Text -> IO Bool
exists = doesPathExist . T.unpack

-- | Where a command is on @PATH@, like @command -v@.
which :: Text -> IO (Maybe Text)
which name = fmap T.pack <$> findExecutable (T.unpack name)

{- | A file's contents as UTF-8 (invalid bytes become U+FFFD).
t'Cantrip.Core.ScriptError' if it cannot be read.
-}
readText :: Text -> IO Text
readText path = do
    r <- try (BS.readFile (T.unpack path)) :: IO (Either IOException BS.ByteString)
    either (\e -> failWith ("cannot read file: " <> path <> ": " <> T.pack (take 120 (show e)))) (return . decodeUtf8Lenient) r

-- | Write a file as UTF-8, replacing it. For files others read concurrently, use 'atomicWriteFile'.
writeText :: Text -> Text -> IO ()
writeText path = BS.writeFile (T.unpack path) . encodeUtf8

-- | Append to a file as UTF-8, creating it if needed.
appendText :: Text -> Text -> IO ()
appendText path = BS.appendFile (T.unpack path) . encodeUtf8

-- | One directory entry, as 'listDir' returns it. Symlinks are not followed.
data Entry = Entry
    { entryName :: Text
    -- ^ The name inside its directory.
    , entryPath :: Text
    -- ^ The directory joined with the name.
    , entrySize :: Integer
    -- ^ Size in bytes.
    , entryModified :: UTCTime
    -- ^ When the entry was last modified, in UTC.
    , entryStatus :: FileStatus
    }

-- | A regular file. A symlink is not one, even when it points at a file.
isFile :: Entry -> Bool
isFile = isRegularFile . entryStatus

-- | A directory. A symlink to a directory is not one here.
isDir :: Entry -> Bool
isDir = isDirectory . entryStatus

-- | A symbolic link.
isSymlink :: Entry -> Bool
isSymlink = isSymbolicLink . entryStatus

-- | The entries of a directory, sorted by name, hidden ones included (like @ls -A@).
listDir :: Text -> IO [Entry]
listDir dir = do
    names <- sort <$> listDirectory (T.unpack dir)
    forM names $ \name -> do
        let path = joinRel (T.unpack dir) name
        status <- getSymbolicLinkStatus path
        return
            Entry
                { entryName = T.pack name
                , entryPath = T.pack path
                , entrySize = fromIntegral (fileSize status)
                , entryModified = posixSecondsToUTCTime (modificationTimeHiRes status)
                , entryStatus = status
                }

{- | Paths matching a pattern, sorted: @*@ and @?@ within a name, @**@ for
any number of directories (@src/**/*.hs@). As in the shell, @*@ and @?@
do not match a leading dot; @**@ skips hidden directories and does not
follow symlinks. No match gives @[]@, never the pattern itself.
-}
glob :: Text -> IO [Text]
glob pat = map T.pack . nub . sort <$> go root parts
  where
    p = T.unpack pat
    (root, rest) = if "/" `isPrefixOf` p then ("/", dropWhile (== '/') p) else (".", p)
    parts = filter (not . null) (splitOn '/' rest)
    go dir [] = return [dir]
    go dir ("**" : more) = concat <$> (mapM (`go` more) =<< subdirs dir)
    go dir (part : more)
        | not (any (`elem` ("*?" :: String)) part) = descend (joinRel dir part) more
        | otherwise = do
            names <- listDirectory dir `catch` unreadable
            concat <$> mapM (\n -> descend (joinRel dir n) more) (filter (matches part) names)
    descend path [] = (\e -> [path | e]) <$> doesPathExist path
    descend path more = doesDirectoryExist path >>= \d -> if d then go path more else return []
    subdirs dir = do
        names <- listDirectory dir `catch` unreadable
        children <- filterM realDir [joinRel dir n | n <- names, not ("." `isPrefixOf` n)]
        (dir :) . concat <$> mapM subdirs children
    realDir path = isDirectory <$> getSymbolicLinkStatus path
    unreadable :: IOException -> IO [FilePath]
    unreadable _ = return []

matches :: String -> String -> Bool
matches pat name = not ("." `isPrefixOf` name && not ("." `isPrefixOf` pat)) && go pat name
  where
    go ('*' : ps) s = any (go ps) (tails s)
    go ('?' : ps) (_ : s) = go ps s
    go (c : ps) (x : s) = c == x && go ps s
    go [] [] = True
    go _ _ = False

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
    (a, _ : b) -> a : splitOn c b
    (a, []) -> [a]

-- | @./x@ reads as @x@, like the shell's own globs.
joinRel :: FilePath -> FilePath -> FilePath
joinRel "." name = name
joinRel dir name = dir FP.</> name

-- | Create a directory and any missing parents, like @mkdir -p@.
mkdirP :: Text -> IO ()
mkdirP = createDirectoryIfMissing True . T.unpack

{- | @copy src dst@: copy a file, or a directory with everything in it,
to @dst@ (like @cp -r src dst@ when @dst@ does not exist yet). Files
keep their permissions and times. Symlinks are copied as the files they
point to.
-}
copy :: Text -> Text -> IO ()
copy src dst = go (T.unpack src) (T.unpack dst)
  where
    go s d = do
        dir <- doesDirectoryExist s
        if dir
            then do
                createDirectory d
                names <- listDirectory s
                forM_ names $ \n -> go (s FP.</> n) (d FP.</> n)
            else copyFileWithMetadata s d

-- | Move or rename a file or directory, like @mv@; across file systems it copies, then removes.
move :: Text -> Text -> IO ()
move src dst =
    renamePath (T.unpack src) (T.unpack dst) `catch` \e ->
        if ioeGetErrorType e == UnsupportedOperation
            then copy src dst >> remove src
            else throwIO e

-- | Remove a file or a directory with everything in it, like @rm -rf@. Missing paths are fine.
remove :: Text -> IO ()
remove = removePathForcibly . T.unpack

-- | Run with a fresh private (0700) temporary directory, removed afterwards whatever happens.
withTempDir :: (Text -> IO a) -> IO a
withTempDir action = do
    base <- getTemporaryDirectory
    bracket (create base) removePathForcibly (action . T.pack)
  where
    create base = do
        (path, h) <- openTempFile base "cantrip"
        hClose h
        removeFile path
        Posix.createDirectory path 0o700
        return path

{- | Read a JSON file under its lock, transform it, write it back
(pretty-printed) atomically. Uses the @path.lock@ directory, so any process speaking
the 'withLockDir' protocol can share the file safely. A failing update
leaves the file untouched.
-}
modifyJsonFile :: Text -> FileMode -> (Value -> IO Value) -> IO ()
modifyJsonFile path mode update = withLockDir (path <> ".lock") $ do
    current <- readJsonFile path
    updated <- update current
    atomicWriteFile path (BL.toStrict (encodePretty updated <> "\n")) mode

{- | Write via temp file + mode + rename, so concurrent readers see the
old file or the new one, never a half-written one. The temp file is
created 0600 in the target directory and removed if the write throws.
There is no @fsync@: after a power loss the file may be stale or empty.
-}
atomicWriteFile :: Text -> BS.ByteString -> FileMode -> IO ()
atomicWriteFile target bytes mode = do
    let path = T.unpack target
    bracketOnError
        (openTempFile (FP.takeDirectory path) (FP.takeFileName path ++ ".tmp"))
        (\(tmp, h) -> hClose h >> quietly (removeFile tmp))
        ( \(tmp, h) -> do
            BS.hPut h bytes
            hClose h
            setFileMode tmp mode
            renameFile tmp path
        )

{- | Take the lock directory (mkdir is atomic), run the action, release.
Speaks npm @proper-lockfile@'s protocol: a lock whose mtime is older
than 30 s belongs to a dead holder and is taken over, and a held lock
has its mtime refreshed every 5 s. That interoperates with
@proper-lockfile@ peers whose @stale@ option is between 10 s (its
default) and 30 s. Waits up to ~35 s for a live lock; any other
failure to create the directory (missing parent, permissions) throws
t'Cantrip.Core.ScriptError' at once. The action should re-read protected state once
the lock is held, since it may have changed while waiting.
-}
withLockDir :: Text -> IO a -> IO a
withLockDir lockPath action = acquire (0 :: Int)
  where
    lock = T.unpack lockPath
    acquire n
        | n >= 700 = failWith ("cannot acquire lock: " <> lockPath)
        | otherwise = do
            r <- try (createDirectory lock)
            case r of
                Right _ -> bracket (forkIO keepFresh) killThread (const action) `finally` quietly (removeDirectory lock)
                Left e
                    | isAlreadyExistsError e -> do
                        stale <- isStale
                        -- shortcut: like proper-lockfile, two waiters can both judge a lock stale and one may remove the other's fresh lock; needs a rename-based takeover to close.
                        when stale (quietly (removeDirectory lock))
                        unless stale (threadDelay 50000)
                        acquire (n + 1)
                    | otherwise -> failWith ("cannot create lock: " <> lockPath <> ": " <> T.pack (show (e :: IOException)))
    isStale = do
        r <- try (getModificationTime lock) :: IO (Either SomeException UTCTime)
        now <- getCurrentTime
        return (either (const False) (\t -> diffUTCTime now t > staleAfter) r)
    keepFresh = do
        threadDelay (floor (touchEvery * 1000000))
        r <- try (getCurrentTime >>= setModificationTime lock) :: IO (Either SomeException ())
        either (const (return ())) (const keepFresh) r

-- | A peer with @stale@ up to 30 s refreshes at least every 15 s, so a younger lock may be alive.
staleAfter :: NominalDiffTime
staleAfter = 30

-- | Half of proper-lockfile's default 10 s stale age, its own refresh margin.
touchEvery :: NominalDiffTime
touchEvery = 5

quietly :: IO () -> IO ()
quietly act = do
    _ <- try act :: IO (Either SomeException ())
    return ()
