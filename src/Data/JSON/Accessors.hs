-- |
-- Module      : Data.JSON.Accessors
-- Description : Public API for compile-time JSON accessor generation
-- Copyright   : (c) 2025, José María Landa Chávez
-- License     : MIT
--
-- This module provides the public API for the @json-accessors@ library.
-- It exposes a single Template Haskell entry point, 'generateAccessors',
-- and the lightweight data wrapper 'JsonCtx'.
--
-- The goal of this library is to make it easy to work with deeply nested
-- JSON data in a type-safe, ergonomic way by generating strongly typed
-- field accessors automatically from a sample JSON file.
--
-- Overview
--
-- The function 'generateAccessors' reads a JSON file at **compile time**
-- and automatically generates one accessor function per primitive JSON field.
-- Each generated function follows the full JSON path in its name, joined by
-- underscores, and extracts its corresponding value from a runtime 'JsonCtx'.
--
-- Example
--
-- Given an input JSON file @example.json@:
--
-- @
-- {
--   "tradeDetails": {
--     "leg1Details": {
--       "priceCurrency": "EUR",
--       "notional": 1000000
--     },
--     "leg2Details": {
--       "priceCurrency": "USD",
--       "notional": 500000
--     }
--   }
-- }
-- @
--
-- Writing:
--
-- @
-- {-# LANGUAGE TemplateHaskell #-}
-- import Data.JSON.Accessors
-- import qualified Data.ByteString.Lazy as B
-- import qualified Data.Aeson as A
--
-- $(generateAccessors "example.json")
--
-- main :: IO ()
-- main = do
--   bytes <- B.readFile "example.json"
--   let Right val = A.eitherDecode bytes
--       ctx = JsonCtx val
--   print (tradeDetails_leg1Details_priceCurrency ctx)
--   print (tradeDetails_leg2Details_notional ctx)
-- @
--
-- Will generate and print:
--
-- @
-- "EUR"
-- 500000.0
-- @
module Data.JSON.Accessors
  ( -- * Core API
    -- | These are the only entities you need to import to use the library.
    generateAccessors,
    JsonCtx(..)
  ) where

import Data.JSON.Internal.Generator
    ( JsonCtx(..), generateAccessors )