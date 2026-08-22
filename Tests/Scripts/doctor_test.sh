#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
doctor="$repo_root/Scripts/doctor.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" "${FAKE_SWIFT_VERSION_OUTPUT:-}"' \
  'elif [ "${1:-}" = "package" ] && [ "${2:-}" = "--version" ]; then' \
  '  [ "${FAKE_SWIFTPM_OK:-0}" = "1" ]' \
  'elif [ "${1:-}" = "-e" ]; then' \
  '  [ "${FAKE_FOUNDATION_OK:-0}" = "1" ]' \
  'fi' > "$fake_bin/swift"
chmod +x "$fake_bin/swift"

fake_podman="$fake_bin/podman"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = "info" ]; then' \
  '  [ "${FAKE_PODMAN_INFO_OK:-0}" = "1" ]' \
  'elif [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" "podman version 5.0.0"' \
  'fi' > "$fake_podman"
chmod +x "$fake_podman"

bash_path="$(command -v bash)"
no_swift_bin="$tmp_dir/no-swift-bin"
mkdir -p "$no_swift_bin"
for utility in awk dirname head sed uname; do
  ln -s "$(command -v "$utility")" "$no_swift_bin/$utility"
done
path_without_swift="$no_swift_bin"

run_case() {
  local name="$1"
  local swift_output="$2"
  local expected_status="$3"
  local expected_text="$4"
  local swiftpm_ok="${5:-1}"
  local foundation_ok="${6:-1}"
  local output
  local status

  set +e
  output="$(
    FAKE_SWIFT_VERSION_OUTPUT="$swift_output" \
      FAKE_SWIFTPM_OK="$swiftpm_ok" \
      FAKE_FOUNDATION_OK="$foundation_ok" \
      DOCTOR_HOST_OS=Darwin \
      PATH="$fake_bin:$PATH" \
      bash "$doctor" "" 2>&1
  )"
  status=$?
  set -e

  if [ "$status" -ne "$expected_status" ]; then
    printf 'FAIL: %s: expected exit %s, got %s\n%s\n' \
      "$name" "$expected_status" "$status" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_text"* ]]; then
    printf 'FAIL: %s: expected output to contain %q\n%s\n' \
      "$name" "$expected_text" "$output" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$name"
}

run_missing_swift_case() {
  local output
  local status

  set +e
  output="$(
    PATH="$path_without_swift" \
      DOCTOR_HOST_OS=Darwin \
      "$bash_path" "$doctor" "" 2>&1
  )"
  status=$?
  set -e

  if [ "$status" -ne 1 ]; then
    printf 'FAIL: missing Swift: expected exit 1, got %s\n%s\n' \
      "$status" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *'Swift toolchain not found on PATH'* ||
    "$output" != *'SwiftPM and Foundation'* ]]; then
    printf 'FAIL: missing Swift: expected a clear installation diagnostic\n%s\n' \
      "$output" >&2
    exit 1
  fi
  printf 'ok: missing Swift\n'
}

run_linux_case() {
  local name="$1"
  local podman_argument="$2"
  local podman_info_ok="$3"
  local expected_status="$4"
  local expected_text="$5"
  local output
  local status

  set +e
  output="$(
    DOCTOR_HOST_OS=Linux \
      FAKE_PODMAN_INFO_OK="$podman_info_ok" \
      PATH="$fake_bin:$path_without_swift" \
      "$bash_path" "$doctor" "$podman_argument" 2>&1
  )"
  status=$?
  set -e

  if [ "$status" -ne "$expected_status" ]; then
    printf 'FAIL: %s: expected exit %s, got %s\n%s\n' \
      "$name" "$expected_status" "$status" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_text"* ]]; then
    printf 'FAIL: %s: expected output to contain %q\n%s\n' \
      "$name" "$expected_text" "$output" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$name"
}

run_missing_swift_case
run_case 'rejects Swift 5.10.1' \
  'Swift version 5.10.1 (swift-5.10.1-RELEASE)' \
  1 'Swift 6.2+'
run_case 'rejects Swift 6.1' \
  'Swift version 6.1 (swift-6.1-RELEASE)' \
  1 'Swift 6.2+'
run_case 'accepts Swift 6.2' \
  'Swift version 6.2 (swift-6.2-RELEASE)' \
  0 'Swift: Swift version 6.2'
run_case 'accepts newer Swift' \
  'Swift version 6.3.3 (swift-6.3.3-RELEASE)' \
  0 'SwiftPM and Foundation available'
run_case 'rejects Swift without SwiftPM' \
  'Swift version 6.3.3 (swift-6.3.3-RELEASE)' \
  1 'SwiftPM is unavailable' 0 1
run_case 'rejects Swift without Foundation' \
  'Swift version 6.3.3 (swift-6.3.3-RELEASE)' \
  1 'cannot import Foundation' 1 0
run_case 'rejects empty output' '' 1 'Swift 6.2+'
run_case 'rejects malformed output' 'not a Swift version' 1 'Swift 6.2+'
run_linux_case 'Linux ignores host Swift and accepts usable Podman' \
  "$fake_podman" 1 0 'host Swift is ignored'
run_linux_case 'Linux requires Podman' '' 0 1 'no native or Docker fallback'
run_linux_case 'Linux reports sandbox-blocked Podman' \
  "$fake_podman" 0 1 'escalated container-runtime permissions'
