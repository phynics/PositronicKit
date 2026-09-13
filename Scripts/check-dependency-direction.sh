#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failed=0

report_failure() {
    printf 'dependency-direction: %s\n' "$1" >&2
    failed=1
}

find_matches() {
    local pattern="$1"
    local path="$2"
    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$path"
    else
        grep -RInE --include='*.swift' "$pattern" "$path"
    fi
}

# PKContracts is the leaf context. It may import Foundation and external packages,
# but it must never import another project module.
if matches="$(find_matches '^(@_exported[[:space:]]+)?import[[:space:]]+(PK[A-Z]|PositronicKit)([[:space:]]|$)' Sources/PKContracts || true)"; then
    if [[ -n "$matches" ]]; then
        report_failure "PKContracts imports another project module:\n$matches"
    fi
fi

# Provider implementations are downstream of the contracts, not of
# the runtime. Keep this check source-based so it catches an inward import before
# SwiftPM happens to hide it behind a transitive dependency.
for module in \
    PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider \
    PKAnthropicProvider PKFoundationModelsProvider
do
    if matches="$(find_matches '^(@_exported[[:space:]]+)?import[[:space:]]+PositronicKit([[:space:]]|$)' "Sources/$module" || true)"; then
        if [[ -n "$matches" ]]; then
            report_failure "$module imports PositronicKit:\n$matches"
        fi
    fi
done

# PKUtilities remains package-internal while its helpers are relocated in later
# work; it must not be advertised as a consumer-facing product.
if grep -nE '^\s*\.library\(name: "PKUtilities"' Package.swift >/dev/null; then
    report_failure "PKUtilities is still declared as a public library product"
fi

target_block() {
    local target="$1"
    awk -v target="$target" '
        $0 == "            name: \"" target "\"," { capture = 1 }
        capture { print }
        capture && /path:/ { exit }
    ' Package.swift
}

for target in \
    PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider \
    PKAnthropicProvider PKFoundationModelsProvider
do
    block="$(target_block "$target")"
    if [[ -z "$block" ]]; then
        report_failure "could not locate target declaration for $target"
    elif grep -q '"PositronicKit"' <<<"$block"; then
        report_failure "$target target depends on PositronicKit"
    fi
done

# The test graph must respect the same boundary. The runtime test target must
# not depend on provider adapters, the examples executable, or the raw OpenAI
# package; provider-touching tests live in PKProviderIntegrationTests so the
# runtime target rebuilds independently of every adapter.
positronic_block="$(target_block "PositronicKitTests")"
if [[ -z "$positronic_block" ]]; then
    report_failure "could not locate target declaration for PositronicKitTests"
else
    for forbidden in \
        PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider \
        PKAnthropicProvider PKFoundationModelsProvider \
        PositronicKitExamples
    do
        if grep -q "\"$forbidden\"" <<<"$positronic_block"; then
            report_failure "PositronicKitTests target depends on $forbidden (move provider-touching tests to PKProviderIntegrationTests)"
        fi
    done
    if grep -q '"OpenAI"' <<<"$positronic_block"; then
        report_failure "PositronicKitTests target depends on the raw OpenAI package (move provider-touching tests to PKProviderIntegrationTests)"
    fi
fi

if (( failed != 0 )); then
    exit 1
fi

echo "Dependency direction checks passed."
