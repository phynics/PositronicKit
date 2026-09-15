#!/usr/bin/env bash
# list_library_products_test.sh — fail-closed tests for Scripts/list-library-products.swift.
#
# `make verify-products` builds whatever this script prints, so a silent
# parsing change here shrinks that gate without failing it. The script is a
# Swift script interpreted at run time, so these cases need a toolchain and
# skip on hosts without one, the same way compile-doc-snippets.sh does.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
script="$repo_root/Scripts/list-library-products.swift"

if ! command -v swift > /dev/null 2>&1; then
    printf 'list_library_products_test: swift not found on PATH; skipping.\n'
    exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# run_case <name> <ok|fails> <expected-stdout> <stdin-json>
# An undecodable description makes the script raise at top level, which Swift
# turns into a trap rather than a chosen status, so the failing cases assert
# "not zero" instead of pinning a number the runtime picks.
run_case() {
    local name="$1"
    local expectation="$2"
    local expected_stdout="$3"
    local input="$4"
    local actual_exit=0
    local actual_stdout
    actual_stdout="$(printf '%s' "$input" | swift "$script" 2> "$tmp_dir/$name.err")" || actual_exit=$?
    if [ "$expectation" = "ok" ] && [ "$actual_exit" -ne 0 ]; then
        printf 'FAIL %s: expected exit 0, got %s\n' "$name" "$actual_exit"
        cat "$tmp_dir/$name.err"
        fail=$((fail + 1))
        return 0
    fi
    if [ "$expectation" = "fails" ]; then
        if [ "$actual_exit" -eq 0 ]; then
            printf 'FAIL %s: expected a non-zero exit, got 0\n' "$name"
            fail=$((fail + 1))
        else
            printf 'ok %s (exit %s)\n' "$name" "$actual_exit"
            pass=$((pass + 1))
        fi
        return 0
    fi
    if [ "$actual_stdout" != "$expected_stdout" ]; then
        printf 'FAIL %s: expected products %q, got %q\n' "$name" "$expected_stdout" "$actual_stdout"
        fail=$((fail + 1))
        return 0
    fi
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
}

libraries_and_executables='{"products":[
  {"name":"PKContracts","type":{"library":["automatic"]}},
  {"name":"PositronicKitExamples","type":{"executable":null}},
  {"name":"PositronicKit","type":{"library":["automatic"]}}
]}'

run_case 'libraries-only' ok $'PKContracts\nPositronicKit' "$libraries_and_executables"
run_case 'executables-only-prints-nothing' ok '' \
    '{"products":[{"name":"PositronicKitExamples","type":{"executable":null}}]}'
run_case 'malformed-json-fails' fails '' 'not json at all'
run_case 'missing-products-key-fails' fails '' '{"targets":[]}'

# The real package description must still yield the products `verify-products`
# expects, so a schema change in `swift package describe` cannot pass silently.
if [ "$fail" -eq 0 ] && (cd "$repo_root" && swift package describe --type json > "$tmp_dir/describe.json" 2> /dev/null); then
    products="$(swift "$script" < "$tmp_dir/describe.json")"
    if ! printf '%s\n' "$products" | grep -qx 'PositronicKit'; then
        printf 'FAIL real-package: PositronicKit missing from the discovered library products\n'
        printf '%s\n' "$products"
        fail=$((fail + 1))
    else
        printf 'ok real-package-lists-positronickit\n'
        pass=$((pass + 1))
    fi
else
    printf 'ok real-package-check-skipped (swift package describe unavailable)\n'
fi

printf 'list_library_products_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
