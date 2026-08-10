#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
doctor="$repo_root/Scripts/doctor.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ] && [ -n "${FAKE_SWIFT_VERSION_OUTPUT:-}" ]; then' \
  '  printf "%s\n" "$FAKE_SWIFT_VERSION_OUTPUT"' \
  'fi' > "$fake_bin/swift"
chmod +x "$fake_bin/swift"

bash_path="$(command -v bash)"
swift_path="$(command -v swift || true)"
swift_dir="${swift_path%/*}"
path_without_swift="$PATH"
if [ -n "$swift_path" ]; then
  path_without_swift="$(printf '%s\n' "$PATH" | awk -v skip="$swift_dir" -F: '{
    result = ""
    for (i = 1; i <= NF; i++) {
      if ($i != skip) result = result (result == "" ? "" : ":") $i
    }
    print result
  }')"
fi

run_case() {
  local name="$1"
  local swift_output="$2"
  local expected_status="$3"
  local expected_text="$4"
  local output
  local status

  set +e
  output="$(
    FAKE_SWIFT_VERSION_OUTPUT="$swift_output" \
      PATH="$fake_bin:$PATH" \
      bash "$doctor" "" "$tmp_dir/pkfastembed" 2>&1
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
      "$bash_path" "$doctor" "" "$tmp_dir/pkfastembed" 2>&1
  )"
  status=$?
  set -e

  if [ "$status" -ne 1 ]; then
    printf 'FAIL: missing Swift: expected exit 1, got %s\n%s\n' \
      "$status" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *'Swift toolchain not found on PATH'* ||
    "$output" != *'Swift 6.1+'* ]]; then
    printf 'FAIL: missing Swift: expected a clear installation diagnostic\n%s\n' \
      "$output" >&2
    exit 1
  fi
  printf 'ok: missing Swift\n'
}

run_missing_swift_case
run_case 'rejects Swift 5.10.1' \
  'Swift version 5.10.1 (swift-5.10.1-RELEASE)' \
  1 'Swift 6.1+'
run_case 'accepts Swift 6.1' \
  'Swift version 6.1 (swift-6.1-RELEASE)' \
  0 'Swift: Swift version 6.1'
run_case 'accepts newer Swift' \
  'Swift version 6.3.3 (swift-6.3.3-RELEASE)' \
  0 'Swift: Swift version 6.3.3'
run_case 'rejects empty output' '' 1 'Swift 6.1+'
run_case 'rejects malformed output' 'not a Swift version' 1 'Swift 6.1+'
