#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_build_dir() {
  if [ -n "${BUILD_DIR:-}" ]; then
    echo "$BUILD_DIR"
    return 0
  fi
  # Prefer the actual SwiftPM product path (Xcode 27 beta uses the
  # .build/out/Products/<config> layout; older toolchains use .build/<triple>/<config>).
  local bin modules
  if bin="$(swift build --show-bin-path 2>/dev/null)" && [ -n "$bin" ]; then
    if ls "$bin"/*.swiftmodule >/dev/null 2>&1 || [ -d "$bin/Modules" ]; then
      echo "$bin"
      return 0
    fi
  fi
  # Legacy SwiftPM layout that the script historically hardcoded.
  if [ -d "$ROOT/.build/arm64-apple-macosx/debug" ]; then
    echo "$ROOT/.build/arm64-apple-macosx/debug"
    return 0
  fi
  echo ""
}

BUILD_DIR="$(resolve_build_dir)"
if [ -d "$BUILD_DIR/Modules" ]; then
  MODULES_DIR="$BUILD_DIR/Modules"
else
  MODULES_DIR="$BUILD_DIR"
fi

if grep -R -n -E '^[[:space:]]*@testable[[:space:]]+import([[:space:]]|$)' \
  "$ROOT/Tests/PositronicKitTests/Stories"; then
  echo "Public Stories must compile with ordinary imports; move internal-only cases to InternalStories." >&2
  exit 1
fi

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
  mkdir -p "$SYMBOLS_DIR/$module_name"

  "$SYMBOLGRAPH_BIN" \
    -module-name "$module_name" \
    -I "$MODULES_DIR" \
    -I "$BUILD_DIR" \
    -output-dir "$SYMBOLS_DIR/$module_name" \
    -pretty-print \
    -minimum-access-level public \
    -sdk "$SDK_PATH" \
    -target "$TARGET_TRIPLE" \
    -module-cache-path "$MODULE_CACHE_DIR"
}

extract_symbol_graph PKContracts
extract_symbol_graph PKPrompt
extract_symbol_graph PositronicKit

# Build dependency archives for the supporting modules so the main convert can
# resolve cross-module links. Each convert runs from a temporary cwd so DocC
# never picks up a stray catalog from the checkout.
CWD_SAFE="$OUTPUT_DIR/cwd"
mkdir -p "$CWD_SAFE"
(
  cd "$CWD_SAFE"
  "$DOCC_BIN" convert \
    --additional-symbol-graph-dir "$SYMBOLS_DIR/PKContracts" \
    --output-dir "$OUTPUT_DIR/PKContracts.doccarchive" \
    --enable-experimental-external-link-support
  "$DOCC_BIN" convert \
    --additional-symbol-graph-dir "$SYMBOLS_DIR/PKPrompt" \
    --output-dir "$OUTPUT_DIR/PKPrompt.doccarchive" \
    --enable-experimental-external-link-support
)

# Main module convert (run from the checkout so diagnostics show real paths).
cd "$ROOT"
"$DOCC_BIN" convert "$ROOT/Sources/PositronicKit/PositronicKit.docc" \
  --additional-symbol-graph-dir "$SYMBOLS_DIR/PositronicKit" \
  --dependency "$OUTPUT_DIR/PKContracts.doccarchive" \
  --dependency "$OUTPUT_DIR/PKPrompt.doccarchive" \
  --output-dir "$OUTPUT_DIR/PositronicKit.doccarchive" \
  --warnings-as-errors \
  --fallback-display-name PositronicKit \
  --fallback-bundle-identifier com.phynics.PositronicKit
