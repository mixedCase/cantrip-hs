# cantrip-hs

Shell scripts in Haskell for Nix environments. Commands and pipelines read like
bash, a failure can't be silently ignored, and JSON, HTTP and files are typed
values. One `import Cantrip`, and scripts run straight from a shebang line: the
first run compiles (about a second), later runs start in about 10 ms.

It's for small scripts you'd otherwise write in bash or Python, when you want
types and no quoting bugs. It runs on Linux and macOS, and needs Nix with
flakes. The full API reference is at <https://mixedcase.github.io/cantrip-hs/>.

> [!WARNING] **Read this before you use it.** This project is mostly vibe-coded
> with a little curation. It's a little bag of tools that likely only makes
> sense to me and my particular itches when doing certain kinds of scripts. Use
> at your own discretion.

## Install

Try it with nothing installed. This opens a shell with `cantrip` on `PATH`, and
it's gone when you exit:

```bash
nix shell github:mixedCase/cantrip-hs#cantrip
```

Save this as `hello`, make it executable (`chmod +x hello`), and run
`./hello world`:

```haskell
#!/usr/bin/env cantrip
import Cantrip

main :: IO ()
main = script $ \argv -> do
    args <- parseArgs ["NAME"] argv
    let name = positional "NAME" args
    run [sh|echo hello ${name}|]
```

That's the whole setup. To keep it, use one of the two ways below.

### Two ways to run a script

|             | `cantrip` runner                            | Nix helpers                                          |
| ----------- | ------------------------------------------- | ---------------------------------------------------- |
| Script form | a single `#!/usr/bin/env cantrip` file      | a Nix package with a binary on `PATH`                |
| Compiles    | on the first run, then the result is cached | when Nix builds it                                   |
| You need    | the runner on `PATH`                        | a flake for your system or project                   |
| Best for    | one-off scripts and quick edits             | scripts you keep, with their libraries declared once |

### Flake input

To use the runner or the Nix helpers from your own flake, add the input to your
`flake.nix`:

```nix
inputs.cantrip-hs = {
  url = "github:mixedCase/cantrip-hs";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### Option A: the `cantrip` runner

The runner compiles a script the first time it runs, and again after each edit.
Every other run starts the cached binary. It caches by the script's contents and
the compiler's path. Upgrading a compiler at the same path, such as a plain
`ghc` on `PATH`, doesn't change the key, so clear the cache then.

- Binaries live in `$XDG_CACHE_HOME/cantrip` (default `~/.cache/cantrip`).
- `CANTRIP_GHC` picks the compiler. The Nix package sets it to a GHC that has
  `cantrip-hs`.
- `CANTRIP_TRACE=1` prints every command before it runs, like `set -x`. The
  trace includes the arguments, so keep it out of logs you share.
- The runner, `mkCantrip` and the no-flakes command below all turn on
  `OverloadedStrings` and `QuasiQuotes`, so scripts need no `LANGUAGE` pragmas.
  Built some other way (cabal, HLS), they need
  `{-# LANGUAGE OverloadedStrings, QuasiQuotes #-}`.

<details>
<summary><b>Put the runner on your system or in your home config</b></summary>

```nix
# NixOS: configuration.nix (or a module)
environment.systemPackages = [ inputs.cantrip-hs.packages.${pkgs.stdenv.hostPlatform.system}.cantrip ];

# Home Manager
home.packages = [ inputs.cantrip-hs.packages.${pkgs.stdenv.hostPlatform.system}.cantrip ];
```

</details>

<details>
<summary><b>Put the runner in a project's flake</b> (scripts in the repo run inside <code>nix develop</code>)</summary>

```nix
# `system` is your flake's system, as usual.
devShells.${system}.default = pkgs.mkShell {
  packages = [ inputs.cantrip-hs.packages.${system}.cantrip ];
};
```

</details>

<details>
<summary><b>Give the runner more Haskell packages</b></summary>

Build the runner with the packages you need, and use it in place of
`packages.${system}.cantrip` above. Scripts it runs can then import `split`.

```nix
inputs.cantrip-hs.lib.mkRunner { inherit pkgs; libraries = hp: [ hp.split ]; }
```

</details>

### Option B: Nix helpers

Use this when your system or project is already a flake. `lib.mkCantrip` builds
a script as a Nix package: it compiles once, during the Nix build, and runs as a
plain binary. A file is one script. A directory is a script of several modules,
built from its `main` argument (default `Main.hs`), and
[`examples/greet-modules`](examples/greet-modules) shows one.

Put the shared libraries in one list, and give each script its own additions on
top of it. In any module where `pkgs` and `inputs` are in scope (in Home
Manager, pass `inputs` with `extraSpecialArgs`):

```nix
let
  # Shared by every script. Add a library here once.
  scriptLibs = hp: [ hp.aeson hp.text ];

  # Per-script libraries go on top of the shared list.
  mkCantrip = args: inputs.cantrip-hs.lib.mkCantrip (args // {
    inherit pkgs;
    libraries = hp: scriptLibs hp ++ (args.libraries or (_: [ ])) hp;
  });
in
{
  home.packages = [
    (mkCantrip { name = "git-sweep"; src = ./scripts/git-sweep.hs; })
    (mkCantrip { name = "tools"; src = ./scripts/tools; })
    (mkCantrip { name = "dump"; src = ./scripts/dump.hs; libraries = hp: [ hp.split ]; })
  ];
}
```

Use the results like any package: `home.packages`, a `devShells` `packages`
list, or `environment.systemPackages`. Scripts are built with `-O2 -Wall` and
the same extensions as the runner, so the same file works under both.

### Without flakes

<details>
<summary><b>Copy the sources into the project</b></summary>

Copy `src/` and `syntax/` into your project, and save your script as `Main.hs`.
Then get a GHC that has the dependencies, and compile:

```nix
# shell.nix
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = [
    (pkgs.haskellPackages.ghcWithPackages (p: with p; [
      aeson aeson-pretty base16-bytestring base64-bytestring bytestring
      directory filepath
      http-client http-conduit http-types iso8601-time process scientific
      text time typed-process unix vector
    ]))
  ];
}
```

```bash
ghc -O2 -Wall -threaded -XOverloadedStrings -XQuasiQuotes -isrc -isyntax --make Main.hs -o tool
```

</details>

## A larger example

Here is a real script. It deletes local branches already merged into a base
branch:

<!-- example: examples/git-sweep.hs -->

```haskell
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
```

```console
$ git-sweep --dry-run
feature-a: add a
feature-b: add b
would delete 2 branches
$ git-sweep --dryrun
error: unknown option: --dryrun
usage: git-sweep [--dry-run] [--base BRANCH]
$ git-sweep --base nope
fatal: malformed object name nope
error: command failed: git (exit 128)
```

If you don't read Haskell, here's how to read it:

- `[sh|git log -1 ${branch}|]` is a command written like a shell line.
  `${branch}` is a Haskell variable and becomes exactly one argument, whatever
  it contains: no quoting, no injection. No shell runs.
- `capture` is `$(…)`, `captureLines` splits it into lines, `succeeds` is
  `if cmd; then`, and `run` just runs the command.
- A failed command stops the script. `script` reports the failure once, as
  `error: …`, and exits 1. Unlike `set -e`, nothing turns this off: not in
  functions, not in conditions, not in the middle of a pipeline.
- `name <- action` runs a step and names its result. `let name = value` names a
  plain value. `\b -> …` is an anonymous function, `f $ x` is `f (x)`, and `<>`
  joins text.
- `parseArgs` reads `--dry-run` and `--base BRANCH`, generates `--help`, and
  rejects anything else.

## Running commands

### Writing a command

| Form                                           | Use it for                                                                    |
| ---------------------------------------------- | ----------------------------------------------------------------------------- |
| `[sh\|git log -n ${count} ${branch}\|]`        | most commands. Reads like a shell line, runs no shell.                        |
| `cmd "git" ["log", "-n", tshow count, branch]` | argument lists built in code. The same command as above.                      |
| `shell "ls *.log \| wc -l"`                    | real shell syntax (globs, redirects, `&&`) in **fixed** text, run by `sh -c`. |
| `a \|> b`                                      | piping one command into another, built from either form.                      |

Inside `[sh|…|]`:

- Words split on whitespace. `'…'` is literal; `"…"` allows `${…}`. Outside
  single quotes, a backslash makes the next character literal. Inside `"…"`, it
  does so only before `"`, `\` and `$`, as in bash.
- `${name}` must be a Haskell variable in scope, of a type with a `ToArgs`
  instance: `Text`, `String`, `Int`, `Integer`, or a list or `Maybe` of those.
  For other types, bind `let s = tshow x` first. On its own, it becomes exactly
  one argument. A list becomes one argument per element, and `Nothing` none
  (handy for optional flags). Inside a longer word, like `--out=${dir}`, it is
  joined into that word.
- `${…}` takes a variable name, not an expression. Bind an expression with `let`
  first; anything else is a compile error.
- `|` separates pipeline stages. Nothing else is special: there are no globs,
  redirects, `$VAR`, `&&` or `;`. So `find ${dir} -name *.hs` passes `*.hs` to
  `find` as it is, with no quoting needed. For a real glob, use `glob` (see
  [Files](#files)) or `shell`.

### Running it

| Function                  | Like                        | Gives                                                   |
| ------------------------- | --------------------------- | ------------------------------------------------------- |
| `run c`                   | `cmd`                       | nothing; output goes to the terminal                    |
| `capture c`               | `$(cmd)`                    | stdout as `Text`, UTF-8, trailing newlines removed      |
| `captureLines c`          | `mapfile -t lines < <(cmd)` | stdout as lines                                         |
| `captureJson c`           | `cmd \| jq .`               | stdout decoded as JSON, into a `Value` or your own type |
| `captureBytes c`          | `$(cmd)` for binary output  | stdout as a `ByteString`, exactly as written            |
| `forLines c (\line -> …)` | `cmd \| while read -r line` | each line as the command prints it                      |
| `succeeds c`              | `if cmd; then`              | `Bool`; a non-zero exit is an answer, not a failure     |
| `exitCode c`              | `cmd; echo $?`              | the exit status as an `Int`                             |

### Settings

| Setting                  | Like                                                          |
| ------------------------ | ------------------------------------------------------------- |
| `c <<< text`             | `cmd <<< "$text"`                                             |
| `withStdinBytes bytes c` | `cmd < file`, for binary input                                |
| `inDir dir c`            | `(cd "$dir" && cmd)`                                          |
| `withEnv [("K", "v")] c` | `K=v cmd`                                                     |
| `quiet c`                | `cmd >/dev/null 2>&1` (`capture` still reads stdout)          |
| `withTimeout 30 c`       | `timeout 30 cmd`                                              |
| `errorTail c`            | on failure, add the last lines of stderr to the error message |

### When a command fails

- `run`, `capture`, `captureLines`, `captureJson`, `captureBytes` and `forLines`
  fail when the command fails. The script stops there, with one message:
  `command failed: git (exit 128)`.
- The message names the program and its exit status. It never includes the
  arguments or the output, because that is where tokens and passwords tend to
  be. `errorTail` opts into the end of stderr for one command.
- A pipeline fails if any stage fails, like `set -o pipefail`. The one
  exception: an early stage stopped by SIGPIPE, as in `yes | head -n 1`. That is
  how `head` stops a producer, so it is not a failure.
- A missing program fails as `command not found: name`, and a missing `inDir`
  directory as `no such directory: dir`.

### The tour

Every pattern above, in one script that runs. CI runs it on every commit.

<!-- example: examples/shell-tour.hs -->

```haskell
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
```

```console
$ shell-tour examples examples/shell-tour.hs
running on Linux
there are TODOs left
ls missing: exit 2
apple
fig
pear
source: examples/bump-counter.hs
source: examples/git-sweep.hs
source: examples/greet-modules/Greet.hs
source: examples/greet-modules/Main.hs
source: examples/refresh-token.hs
source: examples/shell-tour.hs
hi
bin
boot
dev
> #!/usr/bin/env cantrip
> -- Common shell patterns, one per step. Usage: shell-tour DIR FILE
> import Cantrip
4 scripts in examples
note: "first\nsecond\n"
```

Good to know:

- Under `script`, stdout is line-buffered, so the script's output and its
  commands' output appear in the order they happen. Under `jsonScript`, stdout
  carries only the final JSON line. Everything else goes to stderr: `echo`, the
  output of every command, and `--help`.
- `jsonScript` and `script` set stdin, stdout and stderr to UTF-8 whatever the
  locale, so printing non-ASCII text cannot crash the script.
- Feeding stdin while reading stdout (`capture (c <<< big)`) cannot deadlock,
  however large the input.
- For anything this API doesn't cover, `typed-process` is available:
  `import qualified System.Process.Typed as P`.

## Compared with other tools

I wrote `git-sweep` (the larger example above) in eight tools and ran each
version against the same test repository on 2026-10-20. Each version is written
the way that tool's documentation suggests.

| Tool                                        | Lines | Mistyped flag `--dryrun`      | Mistyped branch `--base nope`                   |
| ------------------------------------------- | ----- | ----------------------------- | ----------------------------------------------- |
| **cantrip**                                 | 17    | refused, with usage           | `error: command failed: git (exit 128)`, exit 1 |
| bash, `set -euo pipefail`, shellcheck clean | 22    | refused (hand-written parser) | **"deleted 0 branches", exit 0**                |
| nushell 0.112                               | 12    | refused                       | **"deleted 0 branches", exit 0**                |
| Bun 1.3 `$`                                 | 18    | refused                       | `ShellError`, exit 1                            |
| zx 8.8                                      | 14    | **ignored: branches deleted** | error, exit 1                                   |
| dax 0.50 (Deno)                             | 17    | **ignored: branches deleted** | `ShellError` with a stack trace, exit 1         |
| Python `sh` 2.2                             | 20    | refused                       | traceback with the full command line and output |
| plumbum 1.10                                | 17    | refused                       | traceback                                       |

Why:

- **bash** needs `|| true` after `grep`, which exits 1 when it filters out every
  line. That `|| true` also hides git's failure.
- **nushell** didn't treat a failing external command in the middle of a
  pipeline as an error.
- **zx** and **dax** use argument parsers that accept unknown flags.
- **Python `sh`** first returned corrupted branch names: by default it gives
  commands a terminal, so git started its pager. The fix is `_tty_out=False`.

nushell is shorter, bash starts slightly faster, and the JavaScript and Python
tools need no compile step. Cantrip and Bun got both mistakes right. Python `sh`
and plumbum refused both too, but printed tracebacks.

## Files

Paths are `Text`. These helpers replace the coreutils calls that make up most
shell scripts:

| Function                                        | Like                                                                                                        |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `glob "src/**/*.hs"`                            | `shopt -s globstar; echo src/**/*.hs`. No match gives `[]`, not the pattern.                                |
| `listDir dir`                                   | `ls -A`, as records: `entryName`, `entryPath`, `entrySize`, `entryModified`, `isFile`, `isDir`, `isSymlink` |
| `readText f`, `writeText f t`, `appendText f t` | `cat f`, `> f`, `>> f` (UTF-8)                                                                              |
| `exists p`                                      | `test -e p`                                                                                                 |
| `mkdirP d`                                      | `mkdir -p d`                                                                                                |
| `copy a b`, `move a b`, `remove p`              | `cp -r a b` (to a new name), `mv a b`, `rm -rf p`                                                           |
| `withTempDir (\dir -> …)`                       | `mktemp -d` and a cleanup `trap`; the directory is private (0700)                                           |
| `which "git"`                                   | `command -v git`                                                                                            |
| `cd d`, `pwd`                                   | `cd d`, `pwd`                                                                                               |
| `a </> b`                                       | `"$a/$b"`                                                                                                   |
| `atomicWriteFile f bytes 0o600`                 | write to a temp file, `chmod`, `mv`                                                                         |
| `modifyJsonFile f 0o600 update`                 | lock, read, change, atomic write                                                                            |
| `withLockDir lock action`                       | a `mkdir` lock with stale-lock takeover, compatible with npm's `proper-lockfile`                            |

## Encoding

Bytes as text and back, for keys, hashes and binary command output:

| Function                            | Like                                            |
| ----------------------------------- | ----------------------------------------------- |
| `toHex bytes`, `fromHex text`       | `xxd -p`, `xxd -r -p`                           |
| `toBase64 bytes`, `fromBase64 text` | `base64 -w0`, `base64 -d`                       |
| `fromUtf8 bytes`                    | UTF-8 that must be valid: `Nothing` if it isn't |
| `decodeUtf8Lenient bytes`           | UTF-8, with invalid bytes replaced by U+FFFD    |

Decoders return `Nothing` on bad input (add a message with `expect`). The hex
and base64 decoders ignore whitespace, so wrapped command output decodes as it
is.

## Arguments

`jsonScript` and `script` pass the arguments in as a list. For one or two
positionals, you can pattern-match on it. For anything more, use `parseArgs`.
Its spec lists every argument the script accepts:

| Entry                | Means                                                              |
| -------------------- | ------------------------------------------------------------------ |
| `"dry-run"`          | a switch, `--dry-run`                                              |
| `"retries=N"`        | an option with a value, `--retries N` (`"retries="` shows `VALUE`) |
| `"FILE"` (uppercase) | a required positional argument                                     |
| `"FILES..."`         | any number of further positionals; must be last                    |

```haskell
args <- parseArgs ["dry-run", "retries=N", "FILE"] argv
switch "dry-run" args          -- Bool
option "retries" args          -- Maybe Text
readOption "retries" args      -- IO (Maybe a), e.g. Int; ScriptError if it doesn't parse
positional "FILE" args         -- Text
positionals args               -- [Text], every positional in order
```

- `-h` and `--help` print a usage line built from the spec and the program name,
  then exit 0: `usage: tool [--dry-run] [--retries N] FILE`. Under `jsonScript`
  it goes to stderr, because stdout is reserved for the JSON line.
- To write the usage text yourself, use `parseArgsWith "usage: …" spec argv`.
  `usageText args` returns the usage text in effect.
- `--name` and `-name` mean the same. A value can be passed as `--name VALUE` or
  `--name=VALUE`. If an option is repeated, the last value wins. `--` ends the
  options.
- These fail with the usage text appended: an unknown option, a missing value, a
  value given to a switch, a missing positional, and an extra positional when
  the spec has no `NAME...` entry.
- Asking for a name the spec doesn't declare is a bug in the script, so it
  raises an error instead of returning a default.
- There is no bundling of short flags (`-abc`) and no per-flag help text.

## JSON and HTTP

`jsonScript` is the other entry point. It prints one JSON line that another
program can parse, `{"ok":true,...}` or `{"ok":false,"reason":...}`, and exits 1
on failure. This script refreshes an OAuth token stored in a JSON file:

<!-- example: examples/refresh-token.hs -->

```haskell
#!/usr/bin/env cantrip
-- Exchange a stored OAuth refresh token for a new access token, and save it.
import Cantrip

main :: IO ()
main = jsonScript $ \argv -> do
    args <- parseArgs ["dry-run", "TOKEN_FILE"] argv
    let file = positional "TOKEN_FILE" args

    saved <- readJsonFile file
    refresh <- expect "no refresh token in the file" (str "refresh" saved)

    req <- request "POST https://auth.example.com/oauth/token"
    let form = [("grant_type", "refresh_token"), ("refresh_token", encodeUtf8 refresh)]
    resp <- http (setRequestBodyURLEncoded form req)
    when (getResponseStatusCode resp == 401) (failWith "refresh token rejected; log in again")

    token <- expectJson resp
    access <- expect "no access_token in the response" (str "access_token" token)

    unless (switch "dry-run" args) $
        modifyJsonFile file 0o600 (\current -> return (upsert "access" (String access) current))

    return (object ["expiresIn" .= int "expires_in" token])
```

- `str "refresh" saved` looks up a string field and returns `Nothing` if it is
  missing or not a string. `expect "message" (…)` turns that `Nothing` into a
  failure.
- An HTTP status like 401 is a normal value you test, not an exception. Only
  network failures throw, and their messages name the host, never the request
  headers.
- `modifyJsonFile` locks the file, reads it, applies your change, and writes it
  back atomically with mode `0o600` (owner read and write only).
- `readYamlFile` and `readYamlFileAs` read YAML into the same `Value` or record.
  Duplicate keys fail. YAML 1.1 rules apply, so an unquoted `NO` reads as
  `False`.

## What's in it

| Module             | Covers                                                        |
| ------------------ | ------------------------------------------------------------- |
| `Cantrip.Shell`    | Commands and pipelines: [Running commands](#running-commands) |
| `Cantrip.Fs`       | Files and directories: [Files](#files)                        |
| `Cantrip.Encoding` | Hex, base64 and UTF-8: [Encoding](#encoding)                  |
| `Cantrip.Cli`      | `script`, `jsonScript` and [arguments](#arguments)            |
| `Cantrip.Json`     | [JSON](#json-and-http) files, safe field access, JWT claims   |
| `Cantrip.Yaml`     | YAML files, read as the same values and records as JSON       |
| `Cantrip.Http`     | HTTPS requests and responses: [JSON and HTTP](#json-and-http) |
| `Cantrip.Core`     | `ScriptError`, `failWith`, `expect`, `envOr`, `nowMs`         |
| `Cantrip.Time`     | ISO 8601 timestamps as epoch milliseconds                     |

Every function and type, with its signature, is in the
[API reference](https://mixedcase.github.io/cantrip-hs/).

`Cantrip` also re-exports `Text`, `ByteString`, `encodeUtf8`, `Value(..)`,
`object`, `(.=)`, `toJSON`, `when`, `unless`, `forM_`, and the common
`Data.Maybe` functions.

## Behavior you can rely on

- **No silent failures.** A failed command, request or file read stops the
  script with one message, unless you asked for the exit code (`succeeds`,
  `exitCode`) or for `Nothing` (`orNothing`).
- **No credentials in error messages.** A failed command is reported by program
  name and exit status, a failed request by host.
- **No injection.** A `${variable}` in `[sh|…|]` and every element of a `cmd`
  argument list reach the program as one argument, unchanged.
- **A status code is a value.** `http` does not throw on 404 or 500.
- **No automatic retries.** Only the script knows whether a command or a request
  is safe to repeat.
- **Accessors do not throw on bad input.** `str`, `num` and `int` return
  `Nothing` for missing fields, wrong types, and numbers out of range. `int` is
  exact over the signed and unsigned 64-bit range.
- **Unexpected exceptions still exit cleanly.** `jsonScript` and `script` report
  them in the same format. Ctrl-C and `exitWith` pass through.

## Limitations

- **POSIX only:** Linux and macOS. Windows is not supported, because file modes,
  the lock protocol and process handling depend on POSIX.
- **Tested with GHC 9.10 only.** CI builds with GHC 9.10 from nixpkgs 26.05.
  Other compilers are untested. With `inputs.nixpkgs.follows`, your nixpkgs
  picks the compiler.
- **Text paths and arguments.** A file name or argument that is not valid UTF-8
  has its invalid bytes replaced with U+FFFD, so it no longer names the same
  file.
- **`${…}` takes variable names only**, not expressions.
- **JWTs are not verified.** `jwtPayload` and `jwtClaim` read the claims of
  tokens you already trust. They do not check signatures.
- **Atomic, but not durable.** `atomicWriteFile` does not `fsync`. Readers never
  see a half-written file, but a power loss can leave the file stale or empty.
- **Lock compatibility has limits.** `withLockDir` works with `proper-lockfile`
  peers, but two waiters can take over the same stale lock at once. See the API
  reference for the details.
- **The runner's cache is never pruned.** Delete the cache directory
  (`~/.cache/cantrip` by default) to reclaim the space.

## Development

```bash
nix develop        # GHC, cabal, HLS, fourmolu, hlint
nix flake check    # build + tests with -Werror, fourmolu, hlint, cabal check,
                   # API docs (every export documented), examples (the tour,
                   # git-sweep and greet-modules also run), the Markdown
                   # formatting (`nix fmt` fixes it), and the runner
nix build .#docs   # the API reference as static HTML (result/index.html)
nix fmt            # reflow README.md and CHANGELOG.md to 80 columns
```

## Status

Pre-1.0. Versions follow SemVer, so any 0.x minor release can break the API; see
[CHANGELOG.md](CHANGELOG.md). Pin a commit in your flake lock.

The API reference is at <https://mixedcase.github.io/cantrip-hs/>. Bugs and
questions go to <https://github.com/mixedCase/cantrip-hs/issues>.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
