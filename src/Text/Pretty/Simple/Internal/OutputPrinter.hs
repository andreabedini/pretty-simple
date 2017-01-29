{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

{-|
Module      : Text.Pretty.Simple.Internal.OutputPrinter
Copyright   : (c) Dennis Gosnell, 2016
License     : BSD-style (see LICENSE file)
Maintainer  : cdep.illabout@gmail.com
Stability   : experimental
Portability : POSIX

-}
module Text.Pretty.Simple.Internal.OutputPrinter
  where

#if __GLASGOW_HASKELL__ < 710
-- We don't need this import for GHC 7.10 as it exports all required functions
-- from Prelude
import Control.Applicative
#endif

import Control.Monad.Reader (MonadReader(reader), runReader)
import Data.Data (Data)
import Data.Foldable (fold, foldlM)
import Data.Text.Lazy (Text)
import Data.Text.Lazy.Builder (Builder, fromString, toLazyText)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Text.Pretty.Simple.Internal.Color (ColorOptions(..), colorReset, defaultColorOptionsDarkBg)
import Text.Pretty.Simple.Internal.Output
       (NestLevel(..), Output(..), OutputType(..))

-- | 'UseColor' describes whether or not we want to use color when printing the
-- 'Output' list.
data UseColor
  = NoColor
  | UseColor
  deriving (Data, Eq, Generic, Read, Show, Typeable)

-- | Data-type wrapping up all the options available when rendering the list
-- of 'Output's.
data OutputOptions = OutputOptions
  { outputOptionsIndentAmount :: Int
  -- ^ Number of spaces to use when indenting.  It should probably be either 2
  -- or 4.
  , outputOptionsColorOptions :: Maybe ColorOptions
  -- ^ 
  } deriving (Eq, Generic, Show, Typeable)

-- | Default values for 'OutputOptions'.  'outputOptionsIndentAmount' defaults
-- to 4, and 'outputOptionsUseColor' defaults to 'UseColor'.
defaultOutputOptions :: OutputOptions
defaultOutputOptions =
  OutputOptions
  { outputOptionsIndentAmount = 4
  , outputOptionsColorOptions = Just defaultColorOptionsDarkBg
  }

render :: OutputOptions -> [Output] -> Text
render options outputs = toLazyText $ runReader (renderOutputs outputs) options

renderOutputs
  :: forall m.
     MonadReader OutputOptions m
  => [Output] -> m Builder
renderOutputs = foldlM foldFunc "" . modificationsOutputList
  where
    foldFunc :: Builder -> Output -> m Builder
    foldFunc accum output = mappend accum <$> renderOutput output

renderRaibowParenFor
  :: MonadReader OutputOptions m
  => NestLevel -> Builder -> m Builder
renderRaibowParenFor nest string =
  sequenceFold [useColorRainbowParens nest, pure string, useColorReset]

renderOutput :: MonadReader OutputOptions m => Output -> m Builder
renderOutput (Output nest OutputCloseBrace) = renderRaibowParenFor nest "}"
renderOutput (Output nest OutputCloseBracket) = renderRaibowParenFor nest "]"
renderOutput (Output nest OutputCloseParen) = renderRaibowParenFor nest ")"
renderOutput (Output nest OutputComma) = renderRaibowParenFor nest ","
renderOutput (Output _ OutputIndent) = do
    indentSpaces <- reader outputOptionsIndentAmount
    pure . mconcat $ replicate indentSpaces " "
renderOutput (Output _ OutputNewLine) = pure "\n"
renderOutput (Output nest OutputOpenBrace) = renderRaibowParenFor nest "{"
renderOutput (Output nest OutputOpenBracket) = renderRaibowParenFor nest "["
renderOutput (Output nest OutputOpenParen) = renderRaibowParenFor nest "("
renderOutput (Output _ (OutputOther string)) =
  -- TODO: This probably shouldn't be a string to begin with.
  pure $ fromString string
renderOutput (Output _ (OutputStringLit string)) = do
  sequenceFold
    [ useColorQuote
    , pure "\""
    , useColorString
    -- TODO: This probably shouldn't be a string to begin with.
    , pure $ fromString string
    , useColorQuote
    , pure "\""
    , useColorReset
    ]

useColorQuote :: forall m. MonadReader OutputOptions m => m Builder
useColorQuote = maybe "" colorQuote <$> reader outputOptionsColorOptions

useColorString :: forall m. MonadReader OutputOptions m => m Builder
useColorString = maybe "" colorString <$> reader outputOptionsColorOptions

useColorError :: forall m. MonadReader OutputOptions m => m Builder
useColorError = maybe "" colorError <$> reader outputOptionsColorOptions

useColorNum :: forall m. MonadReader OutputOptions m => m Builder
useColorNum = maybe "" colorNum <$> reader outputOptionsColorOptions

useColorReset :: forall m. MonadReader OutputOptions m => m Builder
useColorReset = maybe "" (const colorReset) <$> reader outputOptionsColorOptions

useColorRainbowParens
  :: forall m.
     MonadReader OutputOptions m
  => NestLevel -> m Builder
useColorRainbowParens nest = do
  maybeOutputColor <- reader outputOptionsColorOptions
  pure $
    case maybeOutputColor of
      Just ColorOptions {colorRainbowParens} -> do
        let choicesLen = length colorRainbowParens
        if choicesLen == 0
          then ""
          else colorRainbowParens !! (unNestLevel nest `mod` choicesLen)
      Nothing -> ""

sequenceFold :: (Monad f, Monoid a, Traversable t) => t (f a) -> f a
sequenceFold = fmap fold . sequence

-- | A function that performs optimizations and modifications to a list of
-- input 'Output's.
--
-- An sample of an optimization is 'removeStartingNewLine' which just removes a
-- newline if it is the first item in an 'Output' list.
modificationsOutputList :: [Output] -> [Output]
modificationsOutputList = shrinkWhitespaceInOthers . compressOthers . removeStartingNewLine

-- | Remove a 'OutputNewLine' if it is the first item in the 'Output' list.
--
-- >>> removeStartingNewLine [Output 3 OutputNewLine, Output 3 OutputComma]
-- [Output {outputNestLevel = NestLevel {unNestLevel = 3}, outputOutputType = OutputComma}]
removeStartingNewLine :: [Output] -> [Output]
removeStartingNewLine ((Output _ OutputNewLine) : t) = t
removeStartingNewLine outputs = outputs

-- | If there are two subsequent 'OutputOther' tokens, combine them into just
-- one 'OutputOther'.
--
-- >>> compressOthers [Output 0 (OutputOther "foo"), Output 0 (OutputOther "bar")]
-- [Output {outputNestLevel = NestLevel {unNestLevel = 0}, outputOutputType = OutputOther "foobar"}]
compressOthers :: [Output] -> [Output]
compressOthers [] = []
compressOthers (Output _ (OutputOther string1):(Output nest (OutputOther string2)):t) =
  compressOthers ((Output nest (OutputOther (string1 `mappend` string2))) : t)
compressOthers (h:t) = h : compressOthers t

-- | In each 'OutputOther' token, compress multiple whitespaces to just one
-- whitespace.
--
-- >>> shrinkWhitespaceInOthers [Output 0 (OutputOther "  hello  ")]
-- [Output {outputNestLevel = NestLevel {unNestLevel = 0}, outputOutputType = OutputOther " hello "}]
shrinkWhitespaceInOthers :: [Output] -> [Output]
shrinkWhitespaceInOthers = fmap shrinkWhitespaceInOther

shrinkWhitespaceInOther :: Output -> Output
shrinkWhitespaceInOther (Output nest (OutputOther string)) =
  Output nest . OutputOther $ shrinkWhitespace string
shrinkWhitespaceInOther other = other

shrinkWhitespace :: String -> String
shrinkWhitespace (' ':' ':t) = shrinkWhitespace (' ':t)
shrinkWhitespace (h:t) = h : shrinkWhitespace t
shrinkWhitespace "" = ""
