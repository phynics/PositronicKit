#!/usr/bin/env bash
# compile_doc_snippets_test.sh — fail-closed tests for Scripts/compile-doc-snippets.sh.
#
# The gate delegates parsing to `swiftc`, so each case stages a fake `swiftc`
# on PATH: one that accepts every snippet and one that rejects them. This
# proves the gate reports success only when parsing succeeds without
# requiring a Swift toolchain.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
gate="$repo_root/Scripts/compile-doc-snippets.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_docs <dir>: a docs tree with one Swift fenced block.
make_docs() {
    local docs="$1"
    mkdir -p "$docs"
    cat > "$docs/Example.md" <<'EOF'
# Example

```swift
let answer = 42
```
EOF
}

# make_swiftc <bin> <exit>: a fake swiftc that always exits <exit>.
make_swiftc() {
    local bin="$1"
    local code="$2"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$bin/swiftc"
    chmod +x "$bin/swiftc"
}

# run_case <name> <swiftc-exit> <expected-exit> [expected-message-substring]
run_case() {
    local name="$1"
    local swiftc_exit="$2"
    local expected_exit="$3"
    local expected_message="${4:-}"
    local case_dir="$tmp_dir/$name"
    make_docs "$case_dir/docs"
    make_swiftc "$case_dir/bin" "$swiftc_exit"
    local output
    local actual_exit=0
    output="$(PATH="$case_dir/bin:$PATH" bash "$gate" "$case_dir/docs" 2>&1)" || actual_exit=$?
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

run_case "parse-success-passes" 0 0 "parsed OK"
run_case "parse-failure-fails" 1 1 "FAIL"

printf 'compile_doc_snippets_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
