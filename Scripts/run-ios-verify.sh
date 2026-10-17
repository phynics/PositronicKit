#!/usr/bin/env bash
# run-ios-verify.sh — build and test the PKObservable adapter on an iOS Simulator.
#
# The macOS and Linux lanes build for their native platform. The provider public
# surface is `@available(anyAppleOS 26, *)`, so a macOS-only availability spelling
# once held a module to the package's iOS 18 floor and broke the iOS build (#206).
# This gate builds and tests on an iOS Simulator destination so that class of
# regression stays caught, and `make verify` runs it on macOS next to the native
# gates. CI runs the same script in its iOS Simulator job.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
derived_data="${IOS_DERIVED_DATA:-$repo_root/.build/ios-simulator}"
log_path="${IOS_VERIFY_LOG:-$repo_root/.build/ios-verify.log}"
mkdir -p "$(dirname "$log_path")"

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'iOS verification requires xcodebuild on PATH; run it on macOS with Xcode installed.\n' >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  printf 'iOS verification requires xcrun on PATH; run it on macOS with Xcode installed.\n' >&2
  exit 1
fi

# An unattended runner has no Xcode UI to approve the vendored `JSONSchemaMacro`
# from `swift-json-schema`, so xcodebuild would refuse it. The macro is already
# pinned through `Package.resolved`, so `-skipMacroValidation` trusts the resolved
# dependency rather than an arbitrary remote macro.
macro_flag=(-skipMacroValidation)

# The runner image installs a different iPhone generation with each Xcode release,
# so pick an available simulator by its UDID instead of a hard-coded device name.
simulator_udid="$(xcrun simctl list devices available \
  | sed -nE 's/^ *iPhone[^(]*\(([0-9A-Fa-f-]+)\).*/\1/p' | head -n 1)"
if [ -z "$simulator_udid" ]; then
  printf 'No available iPhone simulator found; install an iOS Simulator runtime in Xcode.\n' >&2
  xcrun simctl list devices available >&2 || true
  exit 1
fi
printf 'Using iOS Simulator UDID: %s\n' "$simulator_udid"

# `set -o pipefail` at the top of the script makes the pipeline report
# xcodebuild's status instead of tee's, so a failing build or test fails the gate.
run_xcodebuild() {
  xcodebuild "$@" 2>&1 | tee -a "$log_path"
}

run_xcodebuild "${macro_flag[@]}" build \
  -scheme PKObservable \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

run_xcodebuild "${macro_flag[@]}" test \
  -scheme PKObservableTests \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

run_xcodebuild "${macro_flag[@]}" build \
  -scheme PKFoundationModelsProvider \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO
