#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
runner="$repo_root/Scripts/run-linux-container.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    printf 'FAIL: %s: expected failure\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s: expected output to contain %q\n%s\n' \
      "$name" "$expected" "$output" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$name"
}

assert_failure 'requires Podman without native fallback' \
  'no native Linux fallback is supported' \
  env PODMAN="$tmp_dir/missing-podman" bash "$runner" -- true

fake_podman="$tmp_dir/podman"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "info" ]; then' \
  '  echo "permission denied by sandbox" >&2' \
  '  exit 1' \
  'fi' > "$fake_podman"
chmod +x "$fake_podman"

assert_failure 'explains Podman sandbox escalation' \
  'rerun the same make command with escalated container-runtime permissions' \
  env PODMAN="$fake_podman" bash "$runner" -- true
