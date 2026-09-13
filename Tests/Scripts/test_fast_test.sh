#!/usr/bin/env bash
# test_fast_test.sh — verify the Makefile fast-loop selector is fail-closed.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAST_TEST_LOG:?FAST_TEST_LOG is required}"
if [[ "$*" == *"--list-tests"* ]]; then
    if [[ "${FAST_TEST_EMPTY:-0}" == "1" ]]; then
        exit 0
    fi
    printf '%s\n' 'PositronicKitTests.UnitProbe'
    exit 0
fi
exit 0
EOF
chmod +x "$fake_bin/swift"

log="$tmp_dir/swift.log"
PATH="$fake_bin:$PATH" FAST_TEST_LOG="$log" \
    make -C "$repo_root" test-fast FAST_SKIP_TAGS="integration slow" > "$tmp_dir/pass.log"
if ! grep -q -- '--skip tag:integration' "$log" || ! grep -q -- '--skip tag:slow' "$log"; then
    printf 'FAIL: test-fast did not pass both tag exclusions to swift test\n' >&2
    cat "$log" >&2
    exit 1
fi
printf 'ok: test-fast passes tag exclusions and executes the selected tests\n'

if PATH="$fake_bin:$PATH" FAST_TEST_LOG="$log" FAST_TEST_EMPTY=1 \
    make -C "$repo_root" test-fast FAST_SKIP_TAGS="integration" > "$tmp_dir/empty.log" 2>&1; then
    printf 'FAIL: test-fast accepted a zero-test selection\n' >&2
    exit 1
fi
if ! grep -q 'matched zero tests' "$tmp_dir/empty.log"; then
    printf 'FAIL: test-fast did not explain the zero-test failure\n' >&2
    cat "$tmp_dir/empty.log" >&2
    exit 1
fi
printf 'ok: test-fast rejects a zero-test selection\n'
