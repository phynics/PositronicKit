#!/usr/bin/env bash
# validate_docs_test.sh — fail-closed tests for Scripts/validate-docs.sh.
#
# The script is a two-stage wrapper: the public story suites, then the DocC
# gate. Both stages need an Apple toolchain and a built SwiftPM tree, so the
# fixture supplies a `swift` shim on PATH and a stub `validate-docc.sh`, and
# the cases assert the wrapper propagates each stage's exit status instead of
# reporting success when a stage fails.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# make_fixture <dir> <swift-exit> <docc-exit>
make_fixture() {
    local fixture="$1"
    local swift_exit="$2"
    local docc_exit="$3"
    mkdir -p "$fixture/Scripts" "$fixture/bin"
    cp "$repo_root/Scripts/validate-docs.sh" "$fixture/Scripts/"
    cat > "$fixture/bin/swift" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fixture/swift.log"
exit $swift_exit
SHIM
    chmod +x "$fixture/bin/swift"
    cat > "$fixture/Scripts/validate-docc.sh" <<SHIM
#!/usr/bin/env bash
printf 'docc\n' >> "$fixture/docc.log"
exit $docc_exit
SHIM
    chmod +x "$fixture/Scripts/validate-docc.sh"
}

# run_case <name> <swift-exit> <docc-exit> <expected-exit>
run_case() {
    local name="$1"
    local swift_exit="$2"
    local docc_exit="$3"
    local expected_exit="$4"
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$swift_exit" "$docc_exit"
    local actual_exit=0
    PATH="$fixture/bin:$PATH" bash "$fixture/Scripts/validate-docs.sh" > "$fixture/out.log" 2>&1 \
        || actual_exit=$?
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected_exit" "$actual_exit"
        cat "$fixture/out.log"
        fail=$((fail + 1))
        return 0
    fi
    printf 'ok %s\n' "$name"
    pass=$((pass + 1))
}

run_case both-stages-pass 0 0 0
run_case story-suite-failure-fails 1 0 1
run_case docc-failure-fails 0 1 1

# A failing story stage must stop before DocC, so a later green stage can
# never mask it.
fixture="$tmp_dir/story-suite-failure-fails"
if [ -f "$fixture/docc.log" ]; then
    printf 'FAIL short-circuit: DocC ran after the story suites failed\n'
    fail=$((fail + 1))
else
    printf 'ok short-circuit-on-story-failure\n'
    pass=$((pass + 1))
fi

# The story stage must actually select the four public story suites.
fixture="$tmp_dir/both-stages-pass"
for suite in RuntimeSetupStoriesTests ExampleUsageStoriesTests IntroductoryStoriesTests PublicRuntimeStoriesTests; do
    if ! grep -q "$suite" "$fixture/swift.log"; then
        printf 'FAIL story-filter: %s missing from the swift test filter\n' "$suite"
        cat "$fixture/swift.log"
        fail=$((fail + 1))
        continue
    fi
done
if [ "$fail" -eq 0 ]; then
    printf 'ok story-filter-selects-public-suites\n'
    pass=$((pass + 1))
fi

printf 'validate_docs_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
