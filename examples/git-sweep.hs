#!/usr/bin/env cantrip
-- Delete local branches that are already merged into BASE.
import Cantrip

main :: IO ()
main = script $ \argv -> do
    args <- parseArgs ["dry-run", "base=BRANCH"] argv
    let base = fromMaybe "main" (option "base" args)
        dryRun = switch "dry-run" args

    clean <- succeeds [sh|git diff --quiet HEAD|]
    unless clean (failWith "working tree has uncommitted changes")
    current <- capture [sh|git branch --show-current|]

    merged <- captureLines [sh|git branch --merged ${base} --format=%(refname:short)|]
    let doomed = filter (\b -> b /= base && b /= current) merged
    forM_ doomed $ \branch -> do
        subject <- capture [sh|git log -1 --format=%s ${branch}|]
        echo (branch <> ": " <> subject)
        unless dryRun (run [sh|git branch -D -q ${branch}|])

    let verb = if dryRun then "would delete " else "deleted "
    echo (verb <> tshow (length doomed) <> " branches")
