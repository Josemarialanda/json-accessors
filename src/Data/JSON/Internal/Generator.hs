{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Data.JSON.Internal.Generator
-- Description : Template Haskell JSON accessor generator
-- Copyright   : (c) 2025, José María Landa Chávez
-- License     : MIT
--
-- This module implements the core logic of the @json-accessors@ library.
-- It allows compile-time generation of strongly-typed JSON field accessors
-- using Template Haskell. Each generated accessor corresponds to a field
-- path in the input JSON file.
--
-- Nested objects and arrays are traversed recursively.
-- Primitive types (@String@, @Double@, @Bool@, and @Maybe A.Value@) produce
-- accessors, while objects are only recursed into. Arrays of primitives
-- also generate accessors (e.g. @[String]@, @[Double]@, etc.).
--
-- The JSON file is read and parsed **at compile time** via 'runIO', and the
-- Template Haskell splices produce top-level declarations that are compiled
-- into your module.
--
-- For the public API, import "Data.JSON.Accessors".

module Data.JSON.Internal.Generator
  ( generateAccessors,
    JsonCtx(..)
  ) where

import Language.Haskell.TH
    ( mkName,
      clause,
      listE,
      normalB,
      funD,
      sigD,
      Exp,
      Q,
      Type,
      Dec,
      runIO )
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Scientific (toRealFloat)
import Data.List (intercalate)
import Control.Monad (forM)

--------------------------------------------------------------------------------
-- | JSON context wrapper
--------------------------------------------------------------------------------

-- | Simple wrapper type that holds an @Aeson.Value@.
--
-- All generated accessors take a 'JsonCtx' as their input argument and
-- extract nested values from it using pre-computed JSON paths.
newtype JsonCtx = JsonCtx { unJsonCtx :: A.Value }
  deriving (Show)

--------------------------------------------------------------------------------
-- | Type classifier for JSON values
--------------------------------------------------------------------------------

-- | Enumeration of JSON kinds used to determine which accessors to generate.
-- This allows the generator to identify whether a field is a string, number,
-- boolean, object, array, null, or something else.
data JsonKind
  = KindString
  | KindNumber
  | KindBool
  | KindObject
  | KindArrayOf JsonKind
  | KindOther
  deriving (Eq, Show)

-- | Classify a given JSON 'A.Value' into a 'JsonKind' tag.
-- This determines both the Haskell type of the generated accessor and
-- whether recursion should continue.
classifyValue :: A.Value -> JsonKind
classifyValue = \case
  A.String _ -> KindString
  A.Number _ -> KindNumber
  A.Bool _   -> KindBool
  A.Object _ -> KindObject
  A.Array arr ->
    case V.uncons arr of
      Nothing -> KindOther
      Just (x, _) -> KindArrayOf (classifyValue x)
  _ -> KindOther

--------------------------------------------------------------------------------
-- | Entry point
--------------------------------------------------------------------------------

-- | Generate Haskell accessor functions for all primitive JSON fields
-- found in the given file.
--
-- This function reads the JSON file at compile time and generates one
-- top-level function per primitive field (including nested ones).
--
-- Error handling
--
-- * If the JSON is invalid, compilation fails with a descriptive message.
-- * Missing keys or type mismatches will trigger runtime errors when using
--   the generated accessors.
generateAccessors :: FilePath -> Q [Dec]
generateAccessors path = do
  bytes <- runIO (B.readFile path)
  case A.eitherDecode bytes of
    Left err -> fail ("Invalid JSON: " <> err)
    Right (val :: A.Value) -> generateFromValue [] val

--------------------------------------------------------------------------------
-- | Recursive traversal
--------------------------------------------------------------------------------

-- | Traverse an 'A.Value' recursively, collecting and generating accessors
-- for all primitive leaf fields.
--
-- * Objects: recursively explored.
-- * Arrays: recursively explored for element type inference.
-- * Primitives: generate accessors.
generateFromValue :: [String] -> A.Value -> Q [Dec]
generateFromValue pathPrefix (A.Object obj) = do
  concat <$> forM (KM.toList obj) (\(k, v) -> do
    let key = T.unpack (Key.toText k)
    genField (pathPrefix <> [key]) v)
generateFromValue pathPrefix (A.Array arr) = do
  concat <$> forM (zip [0..] (V.toList arr)) (\(i, v) ->
    genField (pathPrefix <> [show i]) v)
generateFromValue _ _ = pure []

--------------------------------------------------------------------------------
-- | Field generator (only emits getters for primitive fields)
--------------------------------------------------------------------------------

-- | Generate Template Haskell declarations for a given JSON field.
--
-- Non-primitive values (objects, arrays of objects) are only recursed into
-- but do not generate top-level accessors themselves.
genField :: [String] -> A.Value -> Q [Dec]
genField fullPath val = case classifyValue val of
  KindObject -> generateFromValue fullPath val
  KindArrayOf KindString -> mkGetter fullPath [t| [String] |] [| unpackStringList |]
  KindArrayOf KindNumber -> mkGetter fullPath [t| [Double] |] [| numberToDoubleList |]
  KindArrayOf KindBool   -> mkGetter fullPath [t| [Bool] |]   [| unpackBoolList |]
  KindArrayOf KindObject -> generateFromValue fullPath val
  KindString -> mkGetter fullPath [t| String |] [| unpackString |]
  KindNumber -> mkGetter fullPath [t| Double |] [| numberToDouble |]
  KindBool   -> mkGetter fullPath [t| Bool |]   [| unpackBool |]
  _          -> pure [] -- ignore nulls, mixed arrays, etc.

--------------------------------------------------------------------------------
-- | Generate accessor function
--------------------------------------------------------------------------------

-- | Construct a top-level accessor function declaration for a single field.
--
-- The resulting function has the form:
--
-- > fieldName :: JsonCtx -> a
-- > fieldName = \ctx -> conv (extract (unJsonCtx ctx) path)
--
-- where:
-- * @conv@ is a type-specific conversion function (e.g. 'unpackString')
-- * @path@ is a precomputed list of JSON keys (as @[Text]@)
mkGetter :: [String] -> Q Type -> Q Exp -> Q [Dec]
mkGetter fullPath typ conv = do
  let funName = mkName (concatPath fullPath)
      body = [| \ctx -> $(conv) (extract (unJsonCtx ctx) $(pathExpr fullPath)) |]
  sig <- sigD funName [t| JsonCtx -> $typ |]
  fun <- funD funName [clause [] (normalB body) []]
  pure [sig, fun]

--------------------------------------------------------------------------------
-- | Extract nested key path from JSON
--------------------------------------------------------------------------------

-- | Retrieve a nested field from a JSON value given its path.
--
-- Throws a runtime error if the path does not exist or type mismatches occur.
extract :: A.Value -> [T.Text] -> A.Value
extract v [] = v
extract (A.Object o) (k:ks) =
  case KM.lookup (Key.fromText k) o of
    Just v' -> extract v' ks
    Nothing -> error ("Missing key: " <> T.unpack k)
extract (A.Array arr) (k:ks)
  | [(i, "")] <- reads (T.unpack k) =
      if i < V.length arr
        then extract (arr V.! i) ks
        else error ("Array index out of bounds: " <> show i)
extract _ _ = error "Invalid path"

--------------------------------------------------------------------------------
-- | Conversion helpers
--------------------------------------------------------------------------------

-- | Convert an 'A.Value' to a 'String'.
unpackString :: A.Value -> String
unpackString (A.String t) = T.unpack t
unpackString _ = error "Expected String"

-- | Convert an 'A.Value' to a 'Double'.
numberToDouble :: A.Value -> Double
numberToDouble (A.Number n) = toRealFloat n
numberToDouble _ = error "Expected Number"

-- | Convert an 'A.Value' to a 'Bool'.
unpackBool :: A.Value -> Bool
unpackBool (A.Bool b) = b
unpackBool _ = error "Expected Bool"

-- | Convert an array of JSON strings to @[String]@.
unpackStringList :: A.Value -> [String]
unpackStringList (A.Array arr) = [unpackString v | v <- V.toList arr]
unpackStringList _ = error "Expected [String]"

-- | Convert an array of JSON numbers to @[Double]@.
numberToDoubleList :: A.Value -> [Double]
numberToDoubleList (A.Array arr) = [numberToDouble v | v <- V.toList arr]
numberToDoubleList _ = error "Expected [Double]"

-- | Convert an array of JSON booleans to @[Bool]@.
unpackBoolList :: A.Value -> [Bool]
unpackBoolList (A.Array arr) = [unpackBool v | v <- V.toList arr]
unpackBoolList _ = error "Expected [Bool]"

--------------------------------------------------------------------------------
-- | Helpers
--------------------------------------------------------------------------------

-- | Construct a Template Haskell list expression @[Text]@ from a list of key names.
pathExpr :: [String] -> Q Exp
pathExpr keys = listE [ [| T.pack k |] | k <- keys ]

-- | Concatenate path segments into a single valid Haskell identifier.
--
-- Unsafe characters (spaces, punctuation, etc.) are replaced with underscores.
concatPath :: [String] -> String
concatPath [] = "root"
concatPath xs = intercalate "_" (fmap sanitize xs)

-- | Replace invalid identifier characters with underscores.
sanitize :: String -> String
sanitize = fmap (\c -> if c `elem` (" -./" :: String) then '_' else c)
