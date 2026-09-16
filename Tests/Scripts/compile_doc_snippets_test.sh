#!/usr/bin/env bash
# compile_doc_snippets_test.sh — fail-closed tests for the docs-snippet gate.
#
# `Scripts/compile-doc-snippets.sh` delegates to
# `Scripts/generate-doc-snippets.py` and then shells out to `swift build` for the
# type-checked blocks and `swiftc -parse` for the ones that opt out. Each case
# stages fake `swift`/`swiftc` binaries on PATH so the gate's pass/fail wiring is
# proven without a Swift toolchain: a gate that loses the build exit status or
# type-checks a skipped block would still turn green here.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
gate="$repo_root/Scripts/compile-doc-snippets.sh"
generator="$repo_root/Scripts/generate-doc-snippets.py"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_docs <docs-dir> <fence-header> <body>
make_docs() {
    local docs="$1"
    local header="$2"
    local body="$3"
    mkdir -p "$docs"
    {
        printf '# Example\n\n```%s\n' "$header"
        printf '%s\n' "$body"
        printf '```\n'
    } > "$docs/Example.md"
}

# make_tool <bin-dir> <name> <exit>: a fake tool that always exits <exit>.
make_tool() {
    local bin="$1"
    local name="$2"
    local code="$3"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$bin/$name"
    chmod +x "$bin/$name"
}

# run_case <name> <swift-exit> <swiftc-exit> <expected-exit> <expected-substring>
run_case() {
    local name="$1"
    local swift_exit="$2"
    local swiftc_exit="$3"
    local expected_exit="$4"
    local expected_message="$5"
    local case_dir="$tmp_dir/$name"
    local bin="$case_dir/bin"
    make_tool "$bin" swift "$swift_exit"
    make_tool "$bin" swiftc "$swiftc_exit"
    local output
    local actual_exit=0
    output="$(
        PATH="$bin:$PATH" DOC_SNIPPET_TARGET_DIR="$case_dir/target" \
            DOC_SNIPPET_PARSE_DIR="$case_dir/parse" \
            bash "$gate" "$case_dir/docs" 2>&1
    )" || actual_exit=$?
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n%s\n' \
            "$name" "$expected_exit" "$actual_exit" "$output"
        fail=$((fail + 1))
        return 0
    fi
    if ! printf '%s\n' "$output" | grep -qF "$expected_message"; then
        printf 'FAIL %s: expected diagnostic %q, got:\n%s\n' \
            "$name" "$expected_message" "$output"
        fail=$((fail + 1))
        return 0
    fi
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
}

# 1. A type-checkable block builds the generated target and reports success.
make_docs "$tmp_dir/typecheck-ok/docs" "swift" 'let answer = 42'
run_case "typecheck-ok" 0 0 0 "1 block(s) type-checked, 0 parse-only, all OK."
if [ -f "$tmp_dir/typecheck-ok/target/Generated/Example.1.swift" ] \
    && grep -q "DocSnippetPrelude" "$tmp_dir/typecheck-ok/target/Generated/Example.1.swift"; then
    printf 'ok typecheck-ok-generates-source\n'
    pass=$((pass + 1))
else
    printf 'FAIL typecheck-ok-generates-source: missing generated wrapper\n'
    fail=$((fail + 1))
fi

# 2. A failing target build fails the gate and surfaces the compiler output.
make_docs "$tmp_dir/typecheck-fail/docs" "swift" 'let answer = 42'
run_case "typecheck-fail" 1 0 1 "FAIL type-check"

# 3. The skip marker routes a block to parse-only, so a failing `swift build`
#    must not be consulted and a passing `swiftc -parse` is enough.
make_docs "$tmp_dir/skip-parse-ok/docs" "swift skip" 'let answer = 42'
run_case "skip-parse-ok" 1 0 0 "parsed OK."
if [ -f "$tmp_dir/skip-parse-ok/parse/Example.1.swift" ] \
    && [ ! -f "$tmp_dir/skip-parse-ok/target/Generated/Example.1.swift" ]; then
    printf 'ok skip-parse-ok-routes-to-parse\n'
    pass=$((pass + 1))
else
    printf 'FAIL skip-parse-ok-routes-to-parse: skip marker not honored\n'
    fail=$((fail + 1))
fi

# 4. A skipped block with a syntax error still fails the parse pass.
make_docs "$tmp_dir/skip-parse-fail/docs" "swift skip" 'let answer = 42'
run_case "skip-parse-fail" 0 1 1 "FAIL parse"

# 5. An empty docs tree passes without a toolchain build.
mkdir -p "$tmp_dir/no-blocks/docs"
run_case "no-blocks" 1 1 0 "no Swift fenced blocks"

# 6. Without swift on PATH the gate skips instead of failing.
mkdir -p "$tmp_dir/no-swift/docs"
make_docs "$tmp_dir/no-swift/docs" "swift" 'let answer = 42'
mkdir -p "$tmp_dir/no-swift/bin"
no_swift_output="$(
    PATH="$tmp_dir/no-swift/bin:$PATH" DOC_SNIPPET_SWIFT=definitely-not-swift \
        DOC_SNIPPET_TARGET_DIR="$tmp_dir/no-swift/target" \
        DOC_SNIPPET_PARSE_DIR="$tmp_dir/no-swift/parse" \
        bash "$gate" "$tmp_dir/no-swift/docs" 2>&1
)" || true
if printf '%s\n' "$no_swift_output" | grep -qF "not found on PATH"; then
    printf 'ok no-swift\n'
    pass=$((pass + 1))
else
    printf 'FAIL no-swift: expected skip diagnostic, got:\n%s\n' "$no_swift_output"
    fail=$((fail + 1))
fi

if [ ! -f "$generator" ]; then
    printf 'FAIL generator-present: %s is missing\n' "$generator"
    fail=$((fail + 1))
else
    printf 'ok generator-present\n'
    pass=$((pass + 1))
fi

printf 'compile_doc_snippets_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
