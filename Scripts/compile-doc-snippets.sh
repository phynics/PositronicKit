#!/usr/bin/env bash
# compile-doc-snippets.sh — syntax-check Swift fenced code blocks in docs/.
#
# Extracts every ```swift block from the markdown under docs/ and runs
# `swiftc -parse` on each. This is a SYNTAX-only gate: it does not type-check
# against the package modules, so it will not by itself catch stale API
# references (a full extract-and-typecheck gate is tracked under PKRR-025). It
# does catch malformed snippets — unbalanced braces, broken switches, stray
# tokens — as a cheap regression guard, and establishes the hook PKRR-025 will
# build on.
#
# The canonical construction / run / event-handling shapes in docs/Usage.md are
# additionally type-checked as part of `PositronicKitExamples`
# (`make verify-examples`), which catches the stale-API class of drift that a
# parse-only gate cannot.
set -euo pipefail

DOCS_DIR="${1:-docs}"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "compile-doc-snippets: swiftc not found on PATH; skipping." >&2
    exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Extract every ```swift fenced block into $tmpdir/<file>.<n>.swift.
while IFS= read -r md; do
    base="$(basename "$md" .md)"
    awk -v outdir="$tmpdir" -v base="$base" '
        /^```swift/ { inblk=1; idx++; next }
        /^```[[:space:]]*$/ && inblk { inblk=0; next }
        inblk { print > (outdir "/" base "." idx ".swift") }
    ' "$md"
done < <(grep -rl --include='*.md' '```swift' "$DOCS_DIR" 2>/dev/null || true)

fail=0
checked=0
shopt -s nullglob
for f in "$tmpdir"/*.swift; do
    [ -s "$f" ] || continue
    checked=$((checked + 1))
    if ! swiftc -parse "$f" >/dev/null 2>"$tmpdir/err.txt"; then
        echo "compile-doc-snippets: FAIL $(basename "$f")"
        sed 's/^/  /' "$tmpdir/err.txt"
        fail=1
    fi
done

if [ "$checked" -eq 0 ]; then
    echo "compile-doc-snippets: no Swift fenced blocks under $DOCS_DIR"
    exit 0
fi

if [ "$fail" -ne 0 ]; then
    echo "compile-doc-snippets: $checked block(s) checked, parse errors above." >&2
    exit 1
fi
echo "compile-doc-snippets: $checked block(s) parsed OK."
