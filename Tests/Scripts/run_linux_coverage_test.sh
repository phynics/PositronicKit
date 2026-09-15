#!/usr/bin/env bash
# run_linux_coverage_test.sh — fail-closed tests for Scripts/run-linux-coverage.sh.
#
# The script drives a real Linux `swift test --enable-code-coverage` run, so
# the fixture supplies a `swift` shim on PATH and a stub normalizer. The cases
# pin the failure modes that would otherwise report green coverage: a failing
# test run, and a coverage report that llvm-cov left missing or empty.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <test-exit> <report-kind>
# report-kind: populated | empty | missing
make_fixture() {
    local fixture="$1"
    local test_exit="$2"
    local report_kind="$3"
    mkdir -p "$fixture/Scripts" "$fixture/bin"
    cp "$repo_root/Scripts/run-linux-coverage.sh" "$fixture/Scripts/"
    local report="$fixture/codecov.json"
    case "$report_kind" in
        populated) printf '{"data":[]}\n' > "$report" ;;
        empty) : > "$report" ;;
        missing) rm -f "$report" ;;
    esac
    cat > "$fixture/bin/swift" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fixture/swift.log"
if [[ "\$*" == *"--show-codecov-path"* ]]; then
    printf '%s\n' "$report"
    exit 0
fi
exit $test_exit
SHIM
    chmod +x "$fixture/bin/swift"
    cat > "$fixture/Scripts/linux-coverage-report.py" <<SHIM
import sys
open("$fixture/normalizer.log", "a").write(" ".join(sys.argv[1:]) + "\n")
SHIM
}

# run_case <name> <test-exit> <report-kind> <expected-exit> [expected-message]
run_case() {
    local name="$1"
    local test_exit="$2"
    local report_kind="$3"
    local expected_exit="$4"
    local expected_message="${5:-}"
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$test_exit" "$report_kind"
    local actual_exit=0
    PATH="$fixture/bin:$PATH" bash "$fixture/Scripts/run-linux-coverage.sh" \
        > "$fixture/out.log" 2>&1 || actual_exit=$?
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected_exit" "$actual_exit"
        cat "$fixture/out.log"
        fail=$((fail + 1))
        return 0
    fi
    if [ -n "$expected_message" ] && ! grep -qF "$expected_message" "$fixture/out.log"; then
        printf 'FAIL %s: expected diagnostic %q\n' "$name" "$expected_message"
        cat "$fixture/out.log"
        fail=$((fail + 1))
        return 0
    fi
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
}

run_case populated-report-passes 0 populated 0
run_case failing-tests-fail 1 populated 1
run_case empty-report-fails 0 empty 1 "Linux coverage report is missing or empty"
run_case missing-report-fails 0 missing 1 "Linux coverage report is missing or empty"

# The clean case must hand the report to the normalizer rather than declare
# success on the raw llvm-cov output.
fixture="$tmp_dir/populated-report-passes"
if ! grep -q -- "--raw-report" "$fixture/normalizer.log" 2>/dev/null; then
    printf 'FAIL normalizer: run-linux-coverage did not invoke the report normalizer\n'
    fail=$((fail + 1))
else
    printf 'ok normalizer-receives-the-raw-report\n'
    pass=$((pass + 1))
fi

# An empty report must stop before the normalizer.
fixture="$tmp_dir/empty-report-fails"
if [ -f "$fixture/normalizer.log" ]; then
    printf 'FAIL short-circuit: the normalizer ran on an empty coverage report\n'
    fail=$((fail + 1))
else
    printf 'ok short-circuit-on-empty-report\n'
    pass=$((pass + 1))
fi

# The scratch-path environment override must reach SwiftPM.
fixture="$tmp_dir/scratch-path"
make_fixture "$fixture" 0 populated
PATH="$fixture/bin:$PATH" LINUX_COVERAGE_SCRATCH_PATH="$fixture/scratch" \
    bash "$fixture/Scripts/run-linux-coverage.sh" > "$fixture/out.log" 2>&1
if ! grep -q -- "--scratch-path $fixture/scratch" "$fixture/swift.log"; then
    printf 'FAIL scratch-path: LINUX_COVERAGE_SCRATCH_PATH did not reach swift test\n'
    cat "$fixture/swift.log"
    fail=$((fail + 1))
else
    printf 'ok scratch-path-reaches-swiftpm\n'
    pass=$((pass + 1))
fi

printf 'run_linux_coverage_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
