#!/usr/bin/env bash
# check_gate_script_coverage_test.sh — fail-closed tests for
# Scripts/check-gate-script-coverage.sh.
#
# The gate resolves Scripts/, Tests/Scripts/, and the Makefile from its own
# location, so each case builds a synthetic repository around a copy of it.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <kind>
make_fixture() {
    local fixture="$1"
    local kind="$2"
    mkdir -p "$fixture/Scripts" "$fixture/Tests/Scripts"
    cp "$repo_root/Scripts/check-gate-script-coverage.sh" "$fixture/Scripts/"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/Scripts/check-example.sh"
    printf '#!/usr/bin/env bash\n# covers check-example.sh\nexit 0\n' \
        > "$fixture/Tests/Scripts/check_example_test.sh"
    printf '#!/usr/bin/env bash\n# covers check-gate-script-coverage.sh\nexit 0\n' \
        > "$fixture/Tests/Scripts/check_gate_script_coverage_test.sh"

    local recipe="\t@bash Tests/Scripts/check_example_test.sh\n\t@bash Tests/Scripts/check_gate_script_coverage_test.sh\n"
    case "$kind" in
        clean) ;;
        untested-script)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/Scripts/check-orphan.sh"
            ;;
        unwired-test)
            printf '#!/usr/bin/env bash\n# covers check-example.sh\nexit 0\n' \
                > "$fixture/Tests/Scripts/check_unwired_test.sh"
            ;;
        stale-reference)
            recipe="$recipe\t@bash Tests/Scripts/check_deleted_test.sh\n"
            ;;
        empty-recipe)
            recipe=""
            ;;
    esac
    printf 'verify-agent-harness:\n%b\nother:\n\t@true\n' "$recipe" > "$fixture/Makefile"
}

# run_case <name> <kind> <expected-exit> [expected-message]
run_case() {
    local name="$1"
    local kind="$2"
    local expected_exit="$3"
    local expected_message="${4:-}"
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$kind"
    local output
    local actual_exit=0
    output="$(bash "$fixture/Scripts/check-gate-script-coverage.sh" 2>&1)" || actual_exit=$?
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

run_case covered-tree-passes clean 0 "Gate script coverage checks passed."
run_case untested-script-fails untested-script 1 \
    "Scripts/check-orphan.sh has no test under Tests/Scripts/"
run_case unwired-test-fails unwired-test 1 \
    "Tests/Scripts/check_unwired_test.sh is not run by the verify-agent-harness target"
run_case stale-harness-reference-fails stale-reference 1 \
    "runs Tests/Scripts/check_deleted_test.sh, which does not exist"
run_case empty-harness-recipe-fails empty-recipe 1 \
    "has no recipe; the script tests would not run"

printf 'check_gate_script_coverage_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
