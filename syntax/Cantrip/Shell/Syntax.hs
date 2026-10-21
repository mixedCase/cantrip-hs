{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- SPDX-License-Identifier: BSD-3-Clause

{- | The command type and the @[sh|...|]@ quasi-quoter. Use them through
@import Cantrip@.

This is a separate library of the same package, depending only on
@base@, @text@ and @template-haskell@: GHC loads a quasi-quoter's whole
package with all its dependencies when it runs one, so keeping it out
of the main library halves what @[sh|...|]@ costs at compile time.
-}
module Cantrip.Shell.Syntax (
    -- * Commands
    Cmd (..),
    Stage (..),
    command,
    cmd,
    shell,
    (|>),

    -- * The quasi-quoter
    sh,
    ToArgs (..),

    -- * Internals, for tests
    Part (..),
    parseCommandLine,
    stageFrom,
) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Maybe (catMaybes, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Language.Haskell.TH (Exp, Q, listE, litE, stringL)
import qualified Language.Haskell.TH as TH
import Language.Haskell.TH.Quote (QuasiQuoter (..))

-- | One program in a pipeline.
data Stage
    = -- | A program and its arguments; no shell involved.
      Exec Text [Text]
    | -- | A line for @sh -c@.
      ShellLine Text

{- | A command or pipeline to run, with how to run it. Build one with
'cmd', 'shell', or @[sh|...|]@, and run it with @run@, @capture@ and
the rest of "Cantrip.Shell".
-}
data Cmd = Cmd
    { cmdStages :: [Stage]
    -- ^ The stages, first to last.
    , cmdInput :: Maybe ByteString
    -- ^ Bytes for the first stage's stdin, from @(<<<)@ or @withStdinBytes@.
    , cmdDir :: Maybe Text
    -- ^ Working directory, from @inDir@.
    , cmdEnv :: [(Text, Text)]
    -- ^ Environment overrides, from @withEnv@.
    , cmdQuiet :: Bool
    -- ^ Discard output, from @quiet@.
    , cmdTimeout :: Maybe Double
    -- ^ Seconds before the command is stopped, from @withTimeout@.
    , cmdErrorTail :: Bool
    -- ^ Keep the end of stderr for failure messages, from @errorTail@.
    }

-- | A pipeline of stages with the default settings.
command :: [Stage] -> Cmd
command stages = Cmd stages Nothing Nothing [] False Nothing False

-- | @cmd "git" ["commit", "-m", msg]@: a program and its arguments, passed as they are.
cmd :: Text -> [Text] -> Cmd
cmd program arguments = command [Exec program arguments]

{- | A line run by @sh -c@, with pipes, redirects and globs. For fixed
text only: anything built from a variable belongs in 'cmd' or @[sh|...|]@.
-}
shell :: Text -> Cmd
shell line = command [ShellLine line]

infixl 1 |>

{- | @a |> b@: pipe @a@'s stdout into @b@, like @a | b@. Settings apply to
the whole pipeline; where both sides set one, the left side wins.
-}
(|>) :: Cmd -> Cmd -> Cmd
a |> b =
    Cmd
        { cmdStages = cmdStages a ++ cmdStages b
        , cmdInput = cmdInput a <|> cmdInput b
        , cmdDir = cmdDir a <|> cmdDir b
        , cmdEnv = cmdEnv a ++ cmdEnv b
        , cmdQuiet = cmdQuiet a || cmdQuiet b
        , cmdTimeout = cmdTimeout a <|> cmdTimeout b
        , cmdErrorTail = cmdErrorTail a || cmdErrorTail b
        }

-- | How a value interpolated with @${...}@ becomes arguments.
class ToArgs a where
    -- | The arguments the value stands for.
    toArgs :: a -> [Text]

instance ToArgs Text where
    toArgs t = [t]

instance {-# OVERLAPPING #-} ToArgs String where
    toArgs s = [T.pack s]

instance ToArgs Int where
    toArgs n = [T.pack (show n)]

instance ToArgs Integer where
    toArgs n = [T.pack (show n)]

-- | Each element is its own argument, like @"${files[@]}"@.
instance (ToArgs a) => ToArgs [a] where
    toArgs = concatMap toArgs

-- | 'Nothing' adds no argument at all: handy for optional flags.
instance (ToArgs a) => ToArgs (Maybe a) where
    toArgs = maybe [] toArgs

-- | A piece of a word: literal text or a @${variable}@.
data Part
    = -- | Literal text.
      Lit String
    | -- | A variable name, from @${name}@.
      Var String
    deriving (Eq, Show)

{- | @[sh|git log -n ${count} --format=%s ${branch}|]@: a command written
like a shell line, with no shell involved.

* Words split on whitespace. Single quotes make a word literal; double quotes
  allow @${...}@;
  outside single quotes, a backslash makes the next character literal.
* @${name}@ is a Haskell variable in scope. On its own it becomes exactly
  one argument, however many spaces it holds; a list becomes one argument
  per element, and 'Nothing' none. Inside a longer word (@--out=${dir}@)
  it is joined into that word. Only variable names, not expressions:
  bind an expression with @let@ first.
* @|@ separates the stages of a pipeline.
* Nothing else is special: no globs, redirects, @$VAR@ or @&&@. Use
  @shell@ for those.
-}
sh :: QuasiQuoter
sh =
    QuasiQuoter
        { quoteExp = either (fail . ("sh: " ++)) build . parseCommandLine
        , quotePat = const (fail "sh: only usable as an expression")
        , quoteType = const (fail "sh: only usable as an expression")
        , quoteDec = const (fail "sh: only usable as an expression")
        }

build :: [[[Part]]] -> Q Exp
build stages = [|command $(listE (map stage stages))|]
  where
    stage ws = [|stageFrom (concat $(listE (map group (runs ws))))|]
    -- Consecutive literal words become one list, which keeps type errors short.
    runs [] = []
    runs ws@(w : _)
        | Just _ <- literal w = let (lits, rest) = span (isJust . literal) ws in Left (mapMaybe literal lits) : runs rest
        | otherwise = Right w : runs (drop 1 ws)
    group (Left lits) = listE [[|T.pack $(litE (stringL l))|] | l <- lits]
    group (Right [Var v]) = [|toArgs $(TH.dyn v)|]
    group (Right parts) = [|[T.concat $(listE (map part parts))]|]
    part (Lit l) = [|T.pack $(litE (stringL l))|]
    part (Var v) = [|T.unwords (toArgs $(TH.dyn v))|]
    literal [Lit l] = Just l
    literal _ = Nothing

-- | Used by the code @[sh|...|]@ generates.
stageFrom :: [Text] -> Stage
stageFrom (program : arguments) = Exec program arguments
stageFrom [] = error "Cantrip.Shell: [sh|...|] produced an empty command (a ${...} expanded to nothing)"

-- | Words of each pipeline stage; @Left@ explains a syntax error.
parseCommandLine :: String -> Either String [[[Part]]]
parseCommandLine input = do
    toks <- lexer input
    stages <- split toks
    if any null stages then Left "empty command in pipeline" else Right stages
  where
    split toks = case break (== Nothing) toks of
        (ws, []) -> Right [catMaybes ws]
        (ws, _ : rest) -> (catMaybes ws :) <$> split rest

-- | Words as @Just@, pipes as @Nothing@.
lexer :: String -> Either String [Maybe [Part]]
lexer s = case dropWhile isSpace s of
    "" -> Right []
    '|' : rest -> (Nothing :) <$> lexer rest
    rest -> do
        (w, rest') <- word [] rest
        (Just (merge w) :) <$> lexer rest'
  where
    word acc str = case str of
        [] -> Right (reverse acc, [])
        c : _ | isSpace c || c == '|' -> Right (reverse acc, str)
        '\'' : r -> case break (== '\'') r of
            (q, '\'' : r') -> word (Lit q : acc) r'
            _ -> Left "unterminated '"
        '"' : r -> dquote (Lit "" : acc) r
        '\\' : c : r -> word (Lit [c] : acc) r
        "\\" -> Left "backslash at the end"
        '$' : '{' : r -> var acc r word
        c : r -> word (Lit [c] : acc) r
    dquote acc str = case str of
        '"' : r -> word acc r
        '\\' : c : r | c `elem` ("\"\\$" :: String) -> dquote (Lit [c] : acc) r
        '$' : '{' : r -> var acc r dquote
        c : r -> dquote (Lit [c] : acc) r
        [] -> Left "unterminated \""
    var acc r k = case break (== '}') r of
        (v, '}' : r') | valid v -> k (Var v : acc) r'
        (v, '}' : _) -> Left ("${" ++ v ++ "}: only a variable name can go inside ${...}")
        _ -> Left "unterminated ${"
    valid v = case v of
        c : cs -> (c == '_' || isAsciiLower c) && all (\x -> x `elem` ("_'" :: String) || isAsciiLower x || isAsciiUpper x || isDigit x) cs
        [] -> False
    merge (Lit a : Lit b : rest) = merge (Lit (a ++ b) : rest)
    merge (p : rest) = p : merge rest
    merge [] = []
