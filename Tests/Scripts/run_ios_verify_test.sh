#!/usr/bin/env bash
# run_ios_verify_test.sh — fail-closed tests for Scripts/run-ios-verify.sh.
#
# The script drives a real `xcodebuild` on an iOS Simulator, so the fixture
# supplies `xcodebuild` and `xcrun` shims. The cases pin the failure modes that
# would otherwise report a green iOS lane: a missing tool, no available
# simulator, and a failing test run. The success case also pins which schemes
# and destinations the gate must build, so a future edit cannot quietly stop
# testing PKObservable.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
runner="$repo_root/Scripts/run-ios-verify.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

report_pass() {
  printf 'ok %s\n' "$1"
  pass=$((pass + 1))
}

report_fail() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

# Link the external utilities the script shells out to, so a probe PATH can
# omit exactly the tool under test.
make_probe_path() {
  local dir="$1"
  local utility
  mkdir -p "$dir"
  for utility in bash cat dirname head mkdir sed tee; do
    ln -sf "$(command -v "$utility")" "$dir/$utility"
  done
}

# make_fixture <dir> <test-exit> <devices>
# test-exit: exit status for the PKObservableTests invocation.
# devices:   output of `xcrun simctl list devices available` (may be empty).
make_fixture() {
  local fixture="$1"
  local test_exit="$2"
  local devices="$3"
  mkdir -p "$fixture/bin"

  cat > "$fixture/bin/xcodebuild" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fixture/xcodebuild.log"
case "\$*" in
  *PKObservableTests*) exit $test_exit ;;
esac
exit 0
SHIM
  chmod +x "$fixture/bin/xcodebuild"

  cat > "$fixture/bin/xcrun" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == "simctl list devices available" ]]; then
  printf '%s' '$devices'
fi
exit 0
SHIM
  chmod +x "$fixture/bin/xcrun"
}

# run_case <name> <expected-exit> <expected-message> <fixture> <path-dir> <isolate-path>
# path-dir holds the tool bin directory for a full fixture, or the probe
# directory for a missing-tool case. isolate-path=1 replaces PATH outright so a
# host-installed xcodebuild cannot make a missing-tool case pass; otherwise
# path-dir is prepended.
run_case() {
  local name="$1"
  local expected_exit="$2"
  local expected_message="$3"
  local fixture="$4"
  local path_dir="$5"
  local isolate_path="$6"
  local case_path="$path_dir:$PATH"
  if [ "$isolate_path" -eq 1 ]; then
    case_path="$path_dir"
  fi
  local actual_exit=0
  PATH="$case_path" \
    IOS_VERIFY_LOG="$fixture/ios-verify.log" \
    IOS_DERIVED_DATA="$fixture/derived-data" \
    bash "$runner" > "$fixture/out.log" 2>&1 || actual_exit=$?
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    report_fail "$name" "expected exit $expected_exit, got $actual_exit"
    cat "$fixture/out.log" >&2 || true
    return 0
  fi
  if [ -n "$expected_message" ] && ! grep -qF -- "$expected_message" "$fixture/out.log"; then
    report_fail "$name" "expected diagnostic $(printf '%q' "$expected_message")"
    cat "$fixture/out.log" >&2 || true
    return 0
  fi
  report_pass "$name"
}

device="    iPhone 17 Pro (11111111-1111-1111-1111-111111111111) (Shutdown)\n"

# A missing xcodebuild must fail before touching the project.
missing_xcode="$tmp_dir/missing-xcode"
mkdir -p "$missing_xcode"
make_probe_path "$missing_xcode/bin"
run_case missing-xcodebuild-fails 1 'iOS verification requires xcodebuild' "$missing_xcode" "$missing_xcode/bin" 1

# A toolchain with xcodebuild but no xcrun must fail closed too.
missing_xcrun="$tmp_dir/missing-xcrun"
mkdir -p "$missing_xcrun/bin"
make_probe_path "$missing_xcrun/bin"
cat > "$missing_xcrun/bin/xcodebuild" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$missing_xcrun/bin/xcodebuild"
run_case missing-xcrun-fails 1 'iOS verification requires xcrun' "$missing_xcrun" "$missing_xcrun/bin" 1

# No installed iPhone simulator runtime must fail with guidance, not silently skip.
no_simulator="$tmp_dir/no-simulator"
make_fixture "$no_simulator" 0 ''
run_case no-available-simulator-fails 1 'No available iPhone simulator found' "$no_simulator" "$no_simulator/bin" 0

# The success path builds PKObservable, tests PKObservableTests on the resolved
# UDID, and builds the iOS-restricted provider.
success="$tmp_dir/success"
make_fixture "$success" 0 "$device"
run_case success-builds-and-tests 0 '' "$success" "$success/bin" 0
if grep -qF -- '-scheme PKObservable ' "$success/xcodebuild.log" \
  && grep -qF -- '-scheme PKObservableTests ' "$success/xcodebuild.log" \
  && grep -qF -- 'platform=iOS Simulator,id=11111111-1111-1111-1111-111111111111' "$success/xcodebuild.log" \
  && grep -qF -- '-scheme PKFoundationModelsProvider ' "$success/xcodebuild.log" \
  && grep -qF -- 'CODE_SIGNING_ALLOWED=NO' "$success/xcodebuild.log"; then
  report_pass success-invokes-every-required-scheme
else
  report_fail success-invokes-every-required-scheme 'xcodebuild log is missing a required scheme or destination'
  cat "$success/xcodebuild.log" >&2 || true
fi

# A failing test run must fail the gate even though the build steps succeed.
failing_tests="$tmp_dir/failing-tests"
make_fixture "$failing_tests" 65 "$device"
run_case failing-tests-fail 65 '' "$failing_tests" "$failing_tests/bin" 0

if [ "$fail" -ne 0 ]; then
  printf 'run-ios-verify tests failed (%s passed, %s failed)\n' "$pass" "$fail" >&2
  exit 1
fi
printf 'run-ios-verify tests passed (%s tests)\n' "$pass"
