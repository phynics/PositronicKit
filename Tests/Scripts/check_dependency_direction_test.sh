#!/usr/bin/env bash
# check_dependency_direction_test.sh — fail-closed tests for Scripts/check-dependency-direction.sh.
#
# Copies the gate script into a synthetic fixture repository so its
# repo-relative scans run against controlled inputs, then asserts the script
# exits non-zero on test-graph violations and zero on a clean graph.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# Build a fixture repo containing the gate script plus the minimal source and
# manifest shape the script scans. $2 selects the PositronicKitTests block:
# "clean" (runtime-only deps) or "violation" (a provider adapter dep).
make_fixture() {
    local fixture="$1"
    local variant="$2"
    mkdir -p "$fixture/Scripts" "$fixture/Sources/PKContracts" \
        "$fixture/Sources/PKOpenAIProvider" "$fixture/Sources/PKOpenRouterProvider" \
        "$fixture/Sources/PKOllamaProvider" "$fixture/Sources/PKAnthropicProvider" \
        "$fixture/Sources/PKFoundationModelsProvider"
    cp "$repo_root/Scripts/check-dependency-direction.sh" "$fixture/Scripts/"
    : > "$fixture/Sources/PKContracts/Empty.swift"
    for module in PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider \
        PKAnthropicProvider PKFoundationModelsProvider; do
        : > "$fixture/Sources/$module/Empty.swift"
    done

    local runtime_tests_block
    if [ "$variant" = "violation" ]; then
        runtime_tests_block='        .testTarget(
            name: "PositronicKitTests",
            dependencies: [
                "PositronicKit",
                "PKOpenAIProvider",
                "PKTestSupport",
            ],
            path: "Tests/PositronicKitTests"
        ),'
    else
        runtime_tests_block='        .testTarget(
            name: "PositronicKitTests",
            dependencies: [
                "PositronicKit",
                "PKTestSupport",
            ],
            path: "Tests/PositronicKitTests"
        ),'
    fi

    {
        printf '%s\n' '// swift-tools-version: 6.2' 'import PackageDescription' '' \
            'let package = Package(' '    name: "Fixture",' '    targets: ['
        printf '%s\n' '        .target(' '            name: "PKContracts",' \
            '            path: "Sources/PKContracts"' '        ),'
        for module in PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider \
            PKAnthropicProvider PKFoundationModelsProvider; do
            printf '%s\n' '        .target(' "            name: \"$module\"," \
                '            dependencies: [' '            ],' \
                "            path: \"Sources/$module\"" '        ),'
        done
        printf '%s\n' "$runtime_tests_block" '    ]' ')'
    } > "$fixture/Package.swift"
}

# run_case <name> <variant> <expected-exit> [expected-message-substring]
run_case() {
    local name="$1"
    local variant="$2"
    local expected_exit="$3"
    local expected_message="${4:-}"
    local fixture="$tmp_dir/$name"
    make_fixture "$fixture" "$variant"
    local output
    local actual_exit=0
    output="$(bash "$fixture/Scripts/check-dependency-direction.sh" 2>&1)" || actual_exit=$?
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

run_case "clean-graph-passes" "clean" 0 "Dependency direction checks passed."
run_case "provider-dep-in-runtime-tests-fails" "violation" 1 "PositronicKitTests target depends on PKOpenAIProvider"

printf 'check_dependency_direction_test: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
