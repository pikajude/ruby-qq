{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Provides some quasiquoters that mimic Ruby's percent-letter syntax.
module RubyQQ (
    -- * Shell exec
    x, xx
    -- * Splitting on whitespace
  , w, ww
    -- * Strings
  , q, qq
    -- * Regular expressions
  , r, ri, rx, rix, (=~)
) where

import Control.Applicative
import Control.Monad
import Data.ByteString.Char8        (ByteString, pack)
import Data.Char
import Data.Function
import Data.Monoid
import Language.Haskell.Exts        (parseExp, ParseResult(..))
import Language.Haskell.Meta hiding (parseExp)
import Language.Haskell.TH
import Language.Haskell.TH.Quote
import System.Process
import System.IO
import Prelude hiding               (lex)
import Text.ParserCombinators.ReadP (readP_to_S)
import Text.Read.Lex
import Text.Regex.PCRE.Light
import Text.Trifecta

class Stringable a where asString :: a -> String

class Stringable' flag a where asString' :: flag -> a -> String

instance (StringPred flag a, Stringable' flag a) => Stringable a where
    asString = asString' (undefined :: flag)

class StringPred flag a | a -> flag where {}

instance StringPred HString String
instance (flag ~ HShowable) => StringPred flag a

instance Stringable' HString String where asString' _ = id
instance Show a => Stringable' HShowable a where asString' _ = show

data HString
data HShowable

expQuoter :: (String -> Q Exp) -> QuasiQuoter
expQuoter lam = QuasiQuoter
              lam
              (error "this quoter cannot be used in pattern context")
              (error "this quoter cannot be used in type context")
              (error "this quoter cannot be used in declaration context")

-- | @[x|script|]@ executes @script@ and returns @(stdout,stderr)@. It has type @'IO' ('String','String')@.
--
-- >>> [x|ls -a | wc -l|]
-- ("       8\n","")
--
-- >>> [x|echo >&2 "Hello, world!"|]
-- ("","Hello, world!\n")
x :: QuasiQuoter
x = expQuoter $
        \str -> [|do
                 (_, Just h, Just he, _) <- createProcess (shell $(stringE str))
                    { std_out = CreatePipe, std_err = CreatePipe }
                 (liftM2 (,) `on` hGetContents) h he|]

-- | @[xx|script|]@ spawns a shell process running @script@ and returns
-- @(hndl_stdin, hndl_stdout, hndl_stderr)@. It has type @'IO'
-- ('Handle','Handle','Handle')@.
--
-- >>> [xx|ls|]
-- ({handle: fd:8},{handle: fd:9},{handle: fd:11})
xx :: QuasiQuoter
xx = expQuoter $
        \str -> [|do
                 (Just hi, Just h, Just he, _) <- createProcess (shell $(stringE str))
                    { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
                 return (hi, h, he)|]

-- | @[w|input|]@ is a list containing @input@ split on all whitespace
-- characters.
--
-- Note that no escape expansion occurs:
--
-- >>> [w|hello\n world!|]
-- ["hello\\n","world!"]
w :: QuasiQuoter
w = expQuoter $
        \str -> case parseString safeWords mempty (' ':str) of
            Success strs -> listE $ map stringE strs
            n -> error $ show n

-- | @[ww|input|]@ is a list containing @input@ split on all whitespace
-- characters, with some extra features:
--
-- * Ruby-style interpolation is supported.
--
-- >>> [ww|foo bar #{ reverse "zab" }|]
-- ["foo","bar","baz"]
--
-- /This feature uses some typeclass magic to convert input into the/
-- /friendliest possible String format. If you encounter errors like "No/
-- /instance for (Stringable' flag [a0])", add a type signature to your/
-- /input./
--
-- * All escape sequences are interpreted.
--
-- >>> [ww|Here\n are\SOH some\x123 special\1132 characters\\!|]
-- ["Here\n","are\SOH","some\291","special\1132","characters\\!"]
ww :: QuasiQuoter
ww = expQuoter $
        \str -> case parseString interpWords mempty (' ':str) of
             Success strs -> listE strs
             Failure n -> error $ show n

-- | @[q|input|]@ is @input@. This quoter is essentially the identity
-- function. It is however a handy shortcut for multiline strings.
q :: QuasiQuoter
q = expQuoter stringE

-- | @[qq|input|]@ is @input@, with interpolation and escape sequences
-- expanded.
--
-- >>> let name = "Brian" in [qq|Hello, #{name}!|]
-- "Hello, Brian!"
qq :: QuasiQuoter
qq = expQuoter interpStr'

-- | @[r|pat|]@ is a regular expression defined by @pat@.
r :: QuasiQuoter
r = expQuoter $ \s -> [|compile (pack $(stringE s)) []|]

-- | @[ri|pat|]@ is @[r|pat|]@, but is case-insensitive.
ri :: QuasiQuoter
ri = expQuoter $ \s -> [|compile (pack $(stringE s)) [caseless]|]

-- | @[rx|pat|]@ is @[r|pat|]@, but ignores whitespace and comments in the
-- regex body.
rx :: QuasiQuoter
rx = expQuoter $ \s -> [|compile (pack $(stringE s)) [extended]|]

-- | @[rix|pat|]@ is a combination of @ri@ and @rx@.
rix :: QuasiQuoter
rix = expQuoter $ \s -> [|compile (pack $(stringE s)) [extended, caseless]|]

-- | @(=~)@ is an infix synonym for 'Text.Regex.PCRE.Light.match', with no
-- exec options provided.
--
-- >>> (pack "foobar") =~ [r|((.)\2)b|]
-- Just ["oob", "oo", "o"]
(=~) :: ByteString -> Regex -> Maybe [ByteString]
s =~ re = Text.Regex.PCRE.Light.match re s []

safeWords :: Parser [String]
safeWords = filter (not . null) <$> many1 (many1 (satisfy isSpace) *> word) where
    word = many $ try ('\\' <$ string "\\\\")
              <|> try (char '\\' *> satisfy isSpace)
              <|> satisfy (not . isSpace)

interpWords :: Parser [Q Exp]
interpWords = many1 (many1 (satisfy isSpace) *> (try (fst <$> expq) <|> word)) where
    word = fmap (stringE . unString . concat) $
            many $ try (string "\\\\")
               <|> try (char '\\' *> string "#")
               <|> try (fmap return $ char '\\' *> satisfy isSpace)
               <|> fmap return (satisfy (not . isSpace))

interpStr' :: String -> Q Exp
interpStr' m = [|concat $(listE (go [] m)) :: String|] where
    go n [] = [stringE n]
    go acc y@('#':'{':_) = case parseString expq mempty y of
        Success (qqq,s) -> stringE acc:qqq:go [] s
        Failure _ -> error "failure"
    go acc ('\\':'#':xs) = go (acc ++ "#") xs
    go acc s = case readLitChar s of
        [(y,xs)] -> go (acc ++ [y]) xs
        _ -> error $ "could not read character literal in " ++ s

interpStr :: Parser [Q Exp]
interpStr = many1 (try (fst <$> expq) <|> word) where
    word = stringE <$> many1 (notChar '\\')

expq :: Parser (Q Exp, String)
expq = do
    _ <- string "#{"
    ex <- expBody ""
    _ <- char '}'
    m <- many anyChar
    return (ex, m)
    where
        expBody s = do
            till <- many (notChar '}')
            let conc = s ++ till
            case parseExp conc of
                ParseOk e -> let m = return $ toExp e in return [e|asString $(m)|]
                _ -> char '}' *> expBody (conc ++ "}")

unString :: String -> String
unString s' = case readP_to_S lex $ '"' : concatMap escape s' ++ "\"" of
    [(String str,"")] -> str
    _ -> error $ "Invalid string literal \"" ++ s' ++ "\" (possibly a bad escape sequence)"
    where escape '"' = "\\\""
          escape m' = [m']

many1 :: Alternative f => f a -> f [a]
many1 f = liftA2 (:) f (many f)
