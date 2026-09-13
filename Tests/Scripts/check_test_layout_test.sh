#!/usr/bin/env bash
# check_test_layout_test.sh — fail-closed tests for Scripts/check-test-layout.sh.
#
# Copies the gate script into synthetic fixture repositories and asserts it
# exits non-zero when a Swift file sits directly in Tests/PositronicKitTests/
# or when a test filename carries a ticket identifier.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <kind>: kind is clean, root-file, or ticket-name.
make_fixture() {
    local fixture="$1"
    local kind="$2"
    mkdir -p "$fixture/Scripts" "$fixture/Tests/PositronicKitTests/Services"
    cp "$repo_root/Scripts/check-test-layout.sh" "$fixture/Scripts/"
    : > "$fixture/Tests/PositronicKitTests/Services/SomeServiceTests.swift"
    case "$kind" in
        root-file)
            : > "$fixture/Tests/PositronicKitTests/StrayRootTests.swift"
            ;;
        ticket-name)
            : > "$fixture/Tests/PositronicKitTests/Services/STAB8SomethingTests.swift"
            ;;
    esac
}

# run_case <name> <kind> <expected-exit> [expected-message-substring]
run_case() {
    local name="$1"
    local kind="$2"
    local expected_exit="$3"
    local expected_message="${4:-}"
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$kind"
    local output
    local actual_exit=0
    output="$(bash "$fixture/Scripts/check-test-layout.sh" 2>&1)" || actual_exit=$?
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

run_case "clean-layout-passes" "clean" 0 "Test layout checks passed."
run_case "root-file-fails" "root-file" 1 "sits directly in Tests/PositronicKitTests"
run_case "ticket-name-fails" "ticket-name" 1 "ticket identifier"

printf 'check_test_layout_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
