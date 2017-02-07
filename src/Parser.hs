{-# LANGUAGE GADTs, OverloadedLists #-}
module Parser where

import Control.Applicative
import Data.HashSet
import Data.Result as Result
import Expr
import Text.Parser.Token
import Text.Parser.Token.Highlight
import Text.Trifecta

parseExpr :: String -> Result.Result Expr
parseExpr s = case parseString expr mempty s of
  Success a -> Result a
  Failure info -> Error [show (_errDoc info)]

expr :: Parser Expr
expr = whiteSpace *> (termP <|> typeP) <* eof
  where typeP = exponentialType <?> "type"
        exponentialType = multiplicativeType `chainr1` ((.->.) <$ op "->") <?> "function type"
        multiplicativeType = additiveType `chainl1` ((.*.) <$ op "*") <?> "product type"
        additiveType = atomicType `chainl1` ((.+.) <$ op "+") <?> "sum type"
        atomicType = typeTP <|> unitTP <|> parens typeP
        typeTP = typeT <$ preword "Type"
        unitTP = unitT <$ preword "Unit"

        termP = application <?> "term"
        application = atomicTerm `chainr1` pure (#) <?> "function application"
        atomicTerm = unitP <|> pairP <|> inLP <|> inRP <|> fstP <|> sndP <|> caseP <|> lambdaP <|> varP
        unitP = unit <$ preword "unit"

        pairP = parens (termP `chainr1` (pair <$ comma)) <?> "tuple"
        fstP = fst' <$ preword "fst" <*> termP
        sndP = snd' <$ preword "snd" <*> termP

        inLP = inL <$ preword "inL" <*> termP
        inRP = inR <$ preword "inR" <*> termP
        caseP = makeCase <$  preword "case"
                         <*> termP <* preword "of"
                         <*> parens lambdaP
                         <*> parens lambdaP

        lambdaP = makeLambda <$  symbol "\\"
                             <*> (N <$> identifier) <* dot
                             <*> termP

        varP = var . N <$> identifier

        op = token . highlight Operator . string

identifier :: Parser String
identifier = ident (IdentifierStyle "identifier" (lower <|> char '_') (alphaNum <|> char '_') reservedWords Identifier ReservedIdentifier)

reservedWords :: HashSet String
reservedWords =  [ "module", "where", "inL", "inR", "fst", "snd", "case", "of", "let", "in" ]

preword :: TokenParsing m => String -> m String
preword s = token (highlight ReservedIdentifier (string s <* notFollowedBy alphaNum))
