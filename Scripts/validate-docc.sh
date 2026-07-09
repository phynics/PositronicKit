#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build/arm64-apple-macosx/debug}"
MODULES_DIR="$BUILD_DIR/Modules"
DOCC_BIN="$(xcrun --find docc)"
SYMBOLGRAPH_BIN="$(xcrun --find swift-symbolgraph-extract)"
SDK_PATH="$(xcrun --show-sdk-path)"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx15.0}"

if [[ ! -x "$DOCC_BIN" ]]; then
  echo "docc not found at $DOCC_BIN" >&2
  exit 1
fi

if [[ ! -x "$SYMBOLGRAPH_BIN" ]]; then
  echo "swift-symbolgraph-extract not found at $SYMBOLGRAPH_BIN" >&2
  exit 1
fi

if [[ ! -d "$MODULES_DIR" ]]; then
  echo "Missing build products at $MODULES_DIR. Run 'swift build' first." >&2
  exit 1
fi

SYMBOLS_DIR="$(mktemp -d /private/tmp/positronickit-symbols.XXXXXX)"
MODULE_CACHE_DIR="$(mktemp -d /private/tmp/positronickit-module-cache.XXXXXX)"
OUTPUT_DIR="$(mktemp -d /private/tmp/positronickit-docc.XXXXXX)"
trap 'rm -rf "$SYMBOLS_DIR" "$MODULE_CACHE_DIR" "$OUTPUT_DIR"' EXIT

extract_symbol_graph() {
  local module_name="$1"

  "$SYMBOLGRAPH_BIN" \
    -module-name "$module_name" \
    -I "$MODULES_DIR" \
    -I "$BUILD_DIR" \
    -output-dir "$SYMBOLS_DIR" \
    -pretty-print \
    -minimum-access-level public \
    -sdk "$SDK_PATH" \
    -target "$TARGET_TRIPLE" \
    -module-cache-path "$MODULE_CACHE_DIR"
}

extract_symbol_graph PKShared
extract_symbol_graph PKPrompt
extract_symbol_graph PositronicKit

"$DOCC_BIN" convert "$ROOT/Sources/PositronicKit/PositronicKit.docc" \
  --additional-symbol-graph-dir "$SYMBOLS_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --warnings-as-errors \
  --fallback-display-name PositronicKit \
  --fallback-bundle-identifier com.phynics.PositronicKit
