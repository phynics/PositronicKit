#!/usr/bin/env bash
# validate_docc_test.sh — fail-closed tests for Scripts/validate-docc.sh.
#
# Copies the gate script into a synthetic fixture repository and asserts the
# public-Stories ordinary-import rule rejects an internal import. The later
# DocC stages need an Apple toolchain and a built SwiftPM tree, neither of
# which a fixture has, so the clean case runs the script under
# `--stories-only` and asserts a real exit 0. That keeps the assertion
# identical on every platform instead of whitelisting whichever tool happens
# to be missing on the host.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <kind>: kind is clean or internal-import.
make_fixture() {
    local fixture="$1"
    local kind="$2"
    mkdir -p "$fixture/Scripts" "$fixture/Tests/PositronicKitTests/Stories" \
        "$fixture/Tests/PKProviderIntegrationTests/Stories"
    cp "$repo_root/Scripts/validate-docc.sh" "$fixture/Scripts/"
    if [ "$kind" = "internal-import" ]; then
        printf '%s\n' '@testable import PositronicKit' 'import Testing' > \
            "$fixture/Tests/PositronicKitTests/Stories/InternalStoriesTests.swift"
    elif [ "$kind" = "provider-internal-import" ]; then
        printf '%s\n' '@testable import PositronicKit' 'import Testing' > \
            "$fixture/Tests/PKProviderIntegrationTests/Stories/InternalStoriesTests.swift"
    else
        printf '%s\n' 'import PositronicKit' 'import Testing' > \
            "$fixture/Tests/PositronicKitTests/Stories/PublicStoriesTests.swift"
    fi
}

# run_case <name> <kind> <expected-exit> [expected-message-substring] [script-args...]
run_case() {
    local name="$1"
    local kind="$2"
    local expected_exit="$3"
    local expected_message="${4:-}"
    shift 4 || shift $#
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$kind"
    local output
    local actual_exit=0
    output="$(bash "$fixture/Scripts/validate-docc.sh" "$@" 2>&1)" || actual_exit=$?
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n%s\n' "$name" "$expected_exit" "$actual_exit" "$output"
        fail=$((fail + 1))
        return 0
    fi
    if [ -n "$expected_message" ] && ! printf '%s\n' "$output" | grep -qF "$expected_message"; then
        printf 'FAIL %s: expected diagnostic %q, got:\n%s\n' "$name" "$expected_message" "$output"
        fail=$((fail + 1))
        return 0
    fi
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
}

run_case "internal-import-fails" "internal-import" 1 "ordinary imports"
run_case "provider-internal-import-fails" "provider-internal-import" 1 "ordinary imports"

# Clean tree under --stories-only: the Stories rule must not fire, the stage
# marker must be present, and the script must exit 0. The flag stops the script
# before the Apple-only DocC stages, so this asserts the same thing on Linux and
# macOS and any other early failure still fails the fixture.
clean_fixture="$tmp_dir/clean-tree-passes-stories-rule"
make_fixture "$clean_fixture" "clean"
clean_output="$(bash "$clean_fixture/Scripts/validate-docc.sh" --stories-only 2>&1)" && clean_exit=0 || clean_exit=$?
if [ "$clean_exit" -ne 0 ]; then
    printf 'FAIL clean-tree-passes-stories-rule: expected exit 0, got %s:\n%s\n' "$clean_exit" "$clean_output"
    fail=$((fail + 1))
elif printf '%s\n' "$clean_output" | grep -qF "ordinary imports"; then
    printf 'FAIL clean-tree-passes-stories-rule: Stories rule fired on a clean tree:\n%s\n' "$clean_output"
    fail=$((fail + 1))
elif ! printf '%s\n' "$clean_output" | grep -qF "DocC public story import checks passed."; then
    printf 'FAIL clean-tree-passes-stories-rule: expected the public story check marker:\n%s\n' "$clean_output"
    fail=$((fail + 1))
else
    printf 'ok clean-tree-passes-stories-rule (exit 0)\n'
    pass=$((pass + 1))
fi

# --stories-only must not become an escape hatch: it runs the rule, it does not
# skip it. A violating tree still has to exit non-zero under the flag.
run_case "stories-only-still-rejects-internal-import" "internal-import" 1 "ordinary imports" --stories-only

# An unrecognised flag must be rejected rather than silently ignored, so a
# typo in a caller cannot quietly turn the gate into a no-op.
run_case "unknown-argument-is-rejected" "clean" 2 "unknown argument" --not-a-real-flag

printf 'validate_docc_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
