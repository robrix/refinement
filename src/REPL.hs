{-# LANGUAGE GADTs #-}
module REPL where

import Control.Applicative
import Control.Monad.Free.Freer
import Data.Result
import Expr
import Parser
import Text.Pretty
import Text.Trifecta hiding (Result)

data REPLF a where
  Prompt :: String -> REPLF String
  Output :: Pretty a => Result a -> REPLF ()

type REPL = Freer REPLF

data Command
  = Run Expr
  | Help
  | Quit
  | Version

prompt :: String -> REPL String
prompt s = Prompt s `andThen` return

output :: Pretty a => Result a -> REPL ()
output a = Output a `andThen` return


andThen :: f x -> (x -> Freer f a) -> Freer f a
andThen = (Freer .) . flip Free


repl :: REPL ()
repl = do
  input <- prompt "λ: "
  case Parser.parseString command input of
    Result Help -> output (Error [ "help info goes here" ] :: Result ())
    error -> output error


command :: Parser Command
command = whiteSpace *> (char ':' *> meta <|> eval) <* eof <?> "command"
  where meta = (Help <$ (long "help" <|> short 'h') <?> "help")
           <|> (Quit <$ (long "quit" <|> short 'q') <?> "quit")
           <|> (Version <$ (long "version" <|> short 'v') <?> "version")

        eval = Run <$> expr <?> "expression"

        short = symbol . (:[])
        long = symbol


runREPL :: REPL a -> IO a
runREPL = iterFreer alg . fmap pure
  where alg :: (x -> IO a) -> REPLF x -> IO a
        alg cont repl = case repl of
          Prompt s -> do
            putStr s
            getLine >>= cont
          Output s -> prettyPrint s >>= cont


-- Instances

instance Pretty Command where
  prettyPrec d command = case command of
    Run expr -> prettyPrec d expr
    Help -> showString ":help"
    Quit -> showString ":quit"
    Version -> showString ":version"
