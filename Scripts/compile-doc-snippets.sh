#!/usr/bin/env bash
# compile-doc-snippets.sh — type-check Swift fenced blocks in docs/.
#
# Extracts every ```swift block from the markdown under docs/ and type-checks it
# against the real public modules. Blocks are written into the compile-only
# `DocSnippetConsumer` target, which imports PositronicKit / PKContracts (and
# the provider and test-support modules the guides use) and is built once with
# `swift build --target DocSnippetConsumer`. A wrong argument label, a removed
# symbol, or a wrong argument type in a guide therefore fails this gate.
#
# Snippets that intentionally use undefined identifiers for brevity get a
# bindable stub from a generated prelude (`kit`, `myLanguageModel`,
# `myRuntimeRepository`, `provider`, ...). A block that is deliberately
# illustrative instead of compilable opts out with the greppable fence marker:
#
#     ```swift skip
#
# Skipped blocks still go through the cheap `swiftc -parse` syntax pass, so the
# escape hatch narrows the gate rather than disabling it. Like this script, it
# is a syntax-only check and does not resolve imports.
#
# A guide that documents main-actor UI helpers (`TimelineController`, ...) opts
# into a main-actor wrapper with the greppable fence marker:
#
#     ```swift main-actor
#
# Every other block keeps the nonisolated wrapper, so the gate stays as strict
# as the code most readers paste into a nonisolated `async` function or actor.
#
# The canonical construction / run / event-handling shapes in docs/Usage.md are
# also mirrored into `PositronicKitExamples` (`make verify-examples`); this gate
# is what covers the rest of the guides.
set -euo pipefail

DOCS_DIR="${1:-docs}"
SWIFT_BIN="${DOC_SNIPPET_SWIFT:-swift}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${DOC_SNIPPET_TARGET_DIR:-$REPO_ROOT/Tests/DocSnippetConsumer}"
GENERATED_DIR="$TARGET_DIR/Generated"
# Skipped blocks are only parse-checked, so they must stay outside the SwiftPM
# target path or `swift build` would compile the raw snippets.
PARSE_DIR="${DOC_SNIPPET_PARSE_DIR:-$REPO_ROOT/.build/doc-snippet-parse}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "compile-doc-snippets: python3 not found on PATH; skipping." >&2
    exit 0
fi

if ! command -v "$SWIFT_BIN" >/dev/null 2>&1; then
    echo "compile-doc-snippets: $SWIFT_BIN not found on PATH; skipping." >&2
    exit 0
fi

summary="$(python3 "$SCRIPT_DIR/generate-doc-snippets.py" "$DOCS_DIR" "$TARGET_DIR" "$PARSE_DIR")"
echo "$summary"
checked="$(printf '%s\n' "$summary" | sed -n 's/.*: \([0-9]*\) type-checked,.*/\1/p')"
skipped="$(printf '%s\n' "$summary" | sed -n 's/.*, \([0-9]*\) parse-only.*/\1/p')"
checked="${checked:-0}"
skipped="${skipped:-0}"

if [ "$checked" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "compile-doc-snippets: no Swift fenced blocks under $DOCS_DIR"
    exit 0
fi

# Cheap syntax-only pass for blocks that opted out of type-checking.
parse_fail=0
parse_available=0
if command -v swiftc >/dev/null 2>&1; then
    parse_available=1
    shopt -s nullglob
    for f in "$PARSE_DIR"/*.swift; do
        [ -s "$f" ] || continue
        if ! swiftc -parse "$f" >/dev/null 2>"$PARSE_DIR/err.txt"; then
            echo "compile-doc-snippets: FAIL parse $(basename "$f")"
            sed 's/^/  /' "$PARSE_DIR/err.txt"
            parse_fail=1
        fi
    done
    rm -f "$PARSE_DIR/err.txt"
fi

if [ "$parse_available" -eq 0 ] && [ "$skipped" -gt 0 ]; then
    echo "compile-doc-snippets: swiftc not found on PATH; $skipped parse-only block(s) not syntax-checked." >&2
fi

if [ "$checked" -eq 0 ]; then
    if [ "$parse_fail" -ne 0 ]; then
        echo "compile-doc-snippets: $skipped parse-only block(s) checked, parse errors above." >&2
        exit 1
    fi
    if [ "$parse_available" -eq 1 ]; then
        echo "compile-doc-snippets: $skipped block(s) parsed OK."
    fi
    exit 0
fi

# One build for every type-checked block. SWIFT_BUILD_FLAGS is exported by the
# Makefile so this gate compiles under the same warnings-as-errors policy as the
# rest of `make verify`; a standalone run without it still type-checks.
build_fail=0
# shellcheck disable=SC2086
if ! "$SWIFT_BIN" build --package-path "$REPO_ROOT" --target DocSnippetConsumer ${SWIFT_BUILD_FLAGS:-} >"$work_dir/build.log" 2>&1; then
    build_fail=1
fi

if [ "$build_fail" -ne 0 ]; then
    echo "compile-doc-snippets: FAIL type-check (generated sources under $GENERATED_DIR)"
    sed 's/^/  /' "$work_dir/build.log"
fi

if [ "$build_fail" -ne 0 ] || [ "$parse_fail" -ne 0 ]; then
    echo "compile-doc-snippets: $checked type-checked, $skipped parse-only; failures above." >&2
    exit 1
fi
echo "compile-doc-snippets: $checked block(s) type-checked, $skipped parse-only, all OK."
