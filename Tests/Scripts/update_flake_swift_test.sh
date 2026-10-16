#!/usr/bin/env bash
# update_flake_swift_test.sh — fail-closed tests for Scripts/update-flake-swift.sh.
#
# The script downloads from swift.org through Nix, so each case substitutes a
# fake `nix` that returns canned hashes and a copied flake in a temporary
# directory. The test never touches the network and never edits the real
# flake.nix.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
script="$repo_root/Scripts/update-flake-swift.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/nix" <<'FAKE_NIX'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "store" ] && [ "${2:-}" = "prefetch-file" ]; then
  # The URL is the final argument.
  url="${*: -1}"
  if [[ "$url" == *aarch64* ]]; then
    printf '{"hash":"sha256-MOCKAARCH64HASH","path":"/nix/store/mock-arm"}\n'
  else
    printf '{"hash":"sha256-MOCKX86HASH","path":"/nix/store/mock-x86"}\n'
  fi
  exit 0
fi
printf 'unexpected nix invocation: %s\n' "$*" >&2
exit 1
FAKE_NIX
chmod +x "$fake_bin/nix"

cp "$repo_root/flake.nix" "$tmp_dir/flake.nix"

report() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

expect_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
  else
    report "$name" "expected $file to contain $needle"
  fi
}

expect_status() {
  local name="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >"$tmp_dir/last-output.txt" 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
  else
    report "$name" "expected exit $expected, got $actual: $(cat "$tmp_dir/last-output.txt")"
  fi
}

# --- happy path -------------------------------------------------------------
NIX="$fake_bin/nix" \
  FLAKE_FILE="$tmp_dir/flake.nix" \
  PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1 >"$tmp_dir/update.out" 2>&1

expect_contains "rewrites swiftVersion" "$tmp_dir/flake.nix" 'swiftVersion = "6.5.1";'
expect_contains "rewrites x86 hash" "$tmp_dir/flake.nix" 'sha256-MOCKX86HASH'
expect_contains "rewrites aarch64 hash" "$tmp_dir/flake.nix" 'sha256-MOCKAARCH64HASH'
expect_contains "rewrites x86 url" "$tmp_dir/flake.nix" \
  'swift-6.5.1-RELEASE-ubuntu24.04.tar.gz'
expect_contains "rewrites aarch64 url" "$tmp_dir/flake.nix" \
  'swift-6.5.1-RELEASE-ubuntu24.04-aarch64.tar.gz'
expect_contains "reports the new version" "$tmp_dir/update.out" 'pinned Swift 6.5.1'

if grep -qF 'swiftVersion = "6.4.0";' "$tmp_dir/flake.nix"; then
  report "removes the old version" 'old swiftVersion binding survived'
else
  printf 'ok %s\n' "removes the old version"
  pass=$((pass + 1))
fi

# The generated block must stay inside the markers so a second run is stable.
cp "$repo_root/flake.nix" "$tmp_dir/flake.nix"
NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/flake.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1 >/dev/null 2>&1
NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/flake.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1 >/dev/null 2>&1
marker_count="$(grep -c 'BEGIN swift-distributions' "$tmp_dir/flake.nix")"
if [ "$marker_count" -eq 1 ]; then
  printf 'ok %s\n' "keeps exactly one generated block"
  pass=$((pass + 1))
else
  report "keeps exactly one generated block" "found $marker_count markers"
fi

# --- failure paths ----------------------------------------------------------
expect_status "rejects a missing version" 2 \
  env NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/flake.nix" PATH="$fake_bin:$PATH" \
  bash "$script"
expect_status "rejects a non-semver version" 2 \
  env NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/flake.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.4

printf '%s\n' 'no markers here' > "$tmp_dir/no-markers.nix"
expect_status "fails when the markers are missing" 1 \
  env NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/no-markers.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1

expect_status "fails when nix is missing" 1 \
  env NIX="$tmp_dir/does-not-exist" FLAKE_FILE="$tmp_dir/flake.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1

expect_status "fails when the flake is missing" 1 \
  env NIX="$fake_bin/nix" FLAKE_FILE="$tmp_dir/does-not-exist.nix" PATH="$fake_bin:$PATH" \
  bash "$script" 6.5.1

printf 'update_flake_swift_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
