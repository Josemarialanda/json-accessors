# json-accessors

> **Generate type-safe JSON field accessors at compile time using Template Haskell.**

`json-accessors` reads a JSON file at **compile time** and automatically generates Haskell functions for accessing its fields — even deeply nested ones.

It eliminates repetitive `Aeson` lookups and lets you write simple, type-safe accessors.

---

## Features

* Generates **Haskell accessors for every primitive JSON field**
* Supports nested objects and arrays
* Automatically infers types (`String`, `Double`, `Bool`, `[String]`, etc.)
* Compile-time validation — invalid JSON fails fast
* Simple runtime usage through the `JsonCtx` wrapper

---

## Example

### Input (`example.json`)

```json
{
  "tradeDetails": {
    "leg1Details": {
      "priceCurrency": "EUR",
      "notional": 1000000
    },
    "leg2Details": {
      "priceCurrency": "USD",
      "notional": 500000
    },
    "currencyInfo": [
      { "priceCurrency": "THB", "notional": 250000 },
      { "priceCurrency": "MXN", "notional": 750000 }
    ]
  }
}
```

---

### Usage

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.ByteString.Lazy as B
import qualified Data.Aeson as A
import Data.JSON.Accessors

-- Generate all accessors at compile time from example.json
$(generateAccessors "example.json")

main :: IO ()
main = do
  bytes <- B.readFile "example.json"
  let Right val = A.eitherDecode bytes
      ctx = JsonCtx val

  -- Access nested object fields
  print (tradeDetails_leg1Details_priceCurrency ctx)  -- "EUR"
  print (tradeDetails_leg2Details_notional ctx)       -- 500000.0

  -- Access list elements by index
  print (tradeDetails_currencyInfo_0_priceCurrency ctx)  -- "THB"
  print (tradeDetails_currencyInfo_1_notional ctx)       -- 750000.0

  -- Access aggregated values across all list elements
  print (tradeDetails_currencyInfo_priceCurrency ctx)    -- ["THB","MXN"]
  print (tradeDetails_currencyInfo_notional ctx)         -- [250000.0,750000.0]
```

---

### Output

```
"EUR"
500000.0
"THB"
750000.0
["THB","MXN"]
[250000.0,750000.0]
```

---

### Notes

* **Normal objects** generate one accessor per field path, for example:

  ```haskell
  tradeDetails_leg1Details_notional :: JsonCtx -> Double
  tradeDetails_leg2Details_priceCurrency :: JsonCtx -> String
  ```

  These correspond to deeply nested fields within standard JSON objects.

* **Lists of objects** generate two kinds of accessors:

  * **Indexed accessors** for each individual list element (e.g. `_0_`, `_1_`):

    ```haskell
    tradeDetails_currencyInfo_0_priceCurrency :: JsonCtx -> String
    tradeDetails_currencyInfo_1_notional       :: JsonCtx -> Double
    ```

  * **Collector accessors** that aggregate all values for a field across the list:

    ```haskell
    tradeDetails_currencyInfo_priceCurrency :: JsonCtx -> [String]
    tradeDetails_currencyInfo_notional      :: JsonCtx -> [Double]
    ```

* All generated functions are **strongly typed** based on the JSON content:

  * For primitive fields: `String`, `Double`, or `Bool`
  * For array fields: `[String]`, `[Double]`, or `[Bool]`

* The **type of an array accessor is determined using the first element** of the array.
  If subsequent elements differ in type (e.g. the first is a string but later ones are numbers),
  the generated accessor will **fail at runtime** when evaluating those inconsistent elements.

* Collector accessors **do not skip null or missing fields** — if any element contains a `null` or a mismatched type, the accessor will **fail at runtime**.

---

## How It Works

At compile time, Template Haskell:

1. Reads and parses the given JSON file.
2. Recursively walks the structure.
3. Generates one top-level accessor for each **primitive** field (string, number, boolean, or list thereof).
4. Names each function by concatenating the full JSON path using underscores.

So for example:

```json
{ "user": { "profile": { "age": 30 } } }
```

becomes:

```haskell
user_profile_age :: JsonCtx -> Double
```

---

## API Summary

| Function                                   | Description                                                             |
| ------------------------------------------ | ----------------------------------------------------------------------- |
| `generateAccessors :: FilePath -> Q [Dec]` | Template Haskell splice that generates field accessors from a JSON file |
| `JsonCtx`                                  | Wrapper around an `Aeson.Value` for runtime field extraction            |

---

## Limitations

* Accessors are generated **at compile time**, so the JSON file **must exist** and be readable during the build process.
* Only **primitive fields** (`String`, `Double`, `Bool`) and **arrays of primitives** produce accessors.
  Nested objects are traversed recursively, but only their primitive fields are exposed.
* Arrays generate accessors based on the **type of their first element**. If later elements have inconsistent or mismatched types, 
  the generated accessors will **fail at runtime** when evaluated.
* The generated accessors assume the **JSON structure remains consistent** between compile time and runtime — mismatched types or missing keys will result in **runtime errors**.

---

## Design & Implementation

Internally, the library is split into two modules:

| Module                         | Responsibility                                                        |
| ------------------------------ | --------------------------------------------------------------------- |
| `Data.JSON.Accessors`          | Public API: re-exports `generateAccessors` and `JsonCtx`              |
| `Data.JSON.Internal.Generator` | Template Haskell engine that reads, analyzes, and generates accessors |

### Architecture overview

```
+------------------------+
| example.json           |
+------------------------+
            │
            ▼
   [ Template Haskell ]
   Reads JSON via runIO
            │
            ▼
  classifyValue :: A.Value -> JsonKind
            │
            ▼
 generateFromValue :: [String] -> A.Value -> Q [Dec]
            │
            ▼
 mkGetter (creates TH functions)
            │
            ▼
+-----------------------------------------------+
| Generated Code                                |
|-----------------------------------------------|
| tradeDetails_leg1Details_priceCurrency :: ... |
| tradeDetails_leg2Details_notional      :: ... |
+-----------------------------------------------+
```

### Generated function structure

Each accessor follows this general pattern:

```haskell
fieldName :: JsonCtx -> a
fieldName = \ctx -> convert (extract (unJsonCtx ctx) path)
```

Where:

| Symbol    | Meaning                                                                       |
| --------- | ----------------------------------------------------------------------------- |
| `ctx`     | The JSON context wrapper (`JsonCtx`)                                          |
| `extract` | Navigates the JSON object using a precomputed `[Text]` path                   |
| `convert` | Converts an `A.Value` to a native Haskell type (`String`, `Double`, etc.)     |
| `path`    | A static list of keys like `["tradeDetails", "leg1Details", "priceCurrency"]` |

### Type inference logic

`json-accessors` classifies JSON values recursively:

| JSON example | Inferred type                      |
| ------------ | ---------------------------------- |
| `"USD"`      | `String`                           |
| `123.45`     | `Double`                           |
| `true`       | `Bool`                             |
| `["a", "b"]` | `[String]`                         |
| `[1, 2, 3]`  | `[Double]`                         |
| `{ ... }`    | recursed into, no accessor emitted |

Arrays of objects are recursed into, while arrays of primitives generate `[a]` accessors.

---

## Using with Nix Flakes

You can easily use this library in another Nix flake-based project.

### 1. Add it as a dependency in your flake inputs

e.g.

```nix
{
  description = "my-app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    json-accessors.url = "github:josemarialanda/json-accessors";
    json-accessors.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, json-accessors, ... }:
    let
      overlay = final: prev: {
        haskell = prev.haskell // {
          packageOverrides = hfinal: hprev:
            prev.haskell.packageOverrides hfinal hprev // {
              my-app = hfinal.callCabal2nix "my-app" ./. { };
              json-accessors = hfinal.callCabal2nix "json-accessors" json-accessors { };
            };
        };
        my-app = final.haskell.lib.compose.justStaticExecutables final.haskellPackages.my-app;
      };
      perSystem = system:
        let
          pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
          hspkgs = pkgs.haskellPackages;
        in
        {
          devShell = hspkgs.shellFor {
            withHoogle = true;
            packages = p: [ p.my-app p.json-accessors ];
            buildInputs = [
              hspkgs.cabal-install
              hspkgs.haskell-language-server
              hspkgs.hlint
              hspkgs.ormolu
              pkgs.bashInteractive
            ];
          };
          defaultPackage = pkgs.my-app;
        };
    in
    { inherit overlay; } // 
      flake-utils.lib.eachDefaultSystem perSystem;
}
```

### 2. Reference it from your `.cabal`

In your `build-depends`:

```cabal
build-depends:
    base >=4.9 && <5,
    ...,
    json-accessors
```

### 3. Import and use

```haskell
import Data.JSON.Accessors
```

Now you can call `$(generateAccessors "yourfile.json")` directly in your project.

---

## Development

To start a development shell with Hoogle, HLint, and Ormolu formatting:

```bash
nix develop
```

Then build or run tests with:

```bash
cabal build
cabal repl
```






