#!/usr/bin/env cantrip
-- Common shell patterns, one per step. Usage: shell-tour DIR FILE
import Cantrip

main :: IO ()
main = script $ \argv -> do
    args <- parseArgs ["DIR", "FILE"] argv
    let dir = positional "DIR" args
        file = positional "FILE" args

    -- ls -ld "$dir": a ${variable} is exactly one argument, however many spaces it holds.
    run [sh|ls -ld ${dir}|]

    -- os=$(uname -s)
    os <- capture [sh|uname -s|]
    echo ("running on " <> os)

    -- if grep -rq TODO "$dir"; then ...
    todos <- succeeds [sh|grep -rq TODO ${dir}|]
    when todos (echo "there are TODOs left")

    -- (cd "$dir" && ls missing >/dev/null 2>&1); echo $?
    missing <- exitCode (quiet (inDir dir [sh|ls missing|]))
    echo ("ls missing: exit " <> tshow missing)

    -- sort <<< "$fruit"
    let fruit = "pear\napple\nfig\n"
    sorted <- capture ([sh|sort|] <<< fruit)
    echo sorted

    -- find "$dir" -name '*.hs' | sort | while read -r path; do ...; done
    -- Nothing is globbed inside [sh|...|], so *.hs reaches find as it is.
    forLines [sh|find ${dir} -name *.hs | sort|] $ \path ->
        echo ("source: " <> path)

    -- GREETING=hi sh -c 'echo "$GREETING"'
    greeting <- capture (withEnv [("GREETING", "hi")] (shell "echo \"$GREETING\""))
    echo greeting

    -- A real shell line, for fixed text with globs, redirects or &&.
    run (shell "ls / | head -n 3")

    -- head -n 3 "$file"
    firstLines <- captureLines [sh|head -n 3 ${file}|]
    forM_ firstLines (\line -> echo ("> " <> line))

    -- Files without commands: globs, a temp dir, reading and writing.
    sources <- glob (dir </> "*.hs")
    echo (tshow (length sources) <> " scripts in " <> dir)
    withTempDir $ \tmp -> do
        writeText (tmp </> "note.txt") "first\n"
        appendText (tmp </> "note.txt") "second\n"
        note <- readText (tmp </> "note.txt")
        echo ("note: " <> tshow note)
