#!/usr/bin/env bash
# check_diagnose_usage_test.sh — fail-closed tests for Scripts/check-diagnose-usage.py.
#
# Copies the gate script into synthetic fixture repositories so its repo-relative
# scan runs against controlled inputs, then asserts it accepts only the reviewed
# `@diagnose(<Group>, as: warning, reason: "...")` shape.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <kind>: kind selects the attribute shape under Sources/.
make_fixture() {
    local fixture="$1"
    local kind="$2"
    mkdir -p "$fixture/Scripts" "$fixture/Sources/Fixture"
    cp "$repo_root/Scripts/check-diagnose-usage.py" "$fixture/Scripts/"
    case "$kind" in
        clean)
            printf '%s\n' \
                '@diagnose(DeprecatedDeclaration, as: warning, reason: "migrate next release")' \
                'func bridge() {}' \
                > "$fixture/Sources/Fixture/Clean.swift"
            ;;
        multiline)
            printf '%s\n' \
                '@diagnose(' \
                '    DeprecatedDeclaration,' \
                '    as: warning,' \
                '    reason: "migrate next release (see RFC 42)"' \
                ')' \
                'func bridge() {}' \
                > "$fixture/Sources/Fixture/Multiline.swift"
            ;;
        ignored)
            printf '%s\n' \
                '@diagnose(DeprecatedDeclaration, as: ignored, reason: "hide it")' \
                'func bridge() {}' \
                > "$fixture/Sources/Fixture/Ignored.swift"
            ;;
        error)
            printf '%s\n' \
                '@diagnose(DeprecatedDeclaration, as: error, reason: "escalate")' \
                'func bridge() {}' \
                > "$fixture/Sources/Fixture/Error.swift"
            ;;
        missing-reason)
            printf '%s\n' \
                '@diagnose(DeprecatedDeclaration, as: warning)' \
                'func bridge() {}' \
                > "$fixture/Sources/Fixture/MissingReason.swift"
            ;;
        empty)
            : > "$fixture/Sources/Fixture/Empty.swift"
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
    output="$(python3 "$fixture/Scripts/check-diagnose-usage.py" 2>&1)" || actual_exit=$?
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

run_case "reviewed-shape-passes" "clean" 0 "Diagnose usage scan passed."
run_case "multiline-review-shape-passes" "multiline" 0 "Diagnose usage scan passed."
run_case "ignored-fails" "ignored" 1 "as: warning"
run_case "error-fails" "error" 1 "as: warning"
run_case "missing-reason-fails" "missing-reason" 1 "as: warning"
run_case "no-usage-passes" "empty" 0 "Diagnose usage scan passed."

printf 'check_diagnose_usage_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
