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
        $0 ~ "^[[:space:]]*name: \"" target "\"," { capture = 1 }
        capture { print }
        # Capture the complete declaration rather than assuming `path:` comes
        # after `dependencies:`. SwiftPM accepts either order.
        capture && /^[[:space:]]*\),[[:space:]]*$/ { exit }
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

# Runtime adapter tier (ADR 0015): optional products that import PositronicKit
# to implement its host-facing protocols. Adapters sit downstream of the
# runtime; the runtime and providers never import them, and adapters never
# import providers or each other.
ADAPTERS="PKObservable PKSQLiteStorage PKMCP"
PROVIDERS="PKOpenAIProvider PKOpenRouterProvider PKOllamaProvider PKAnthropicProvider PKFoundationModelsProvider"

# The runtime must never import an adapter.
for adapter in $ADAPTERS; do
    if matches="$(find_matches '^(@_exported[[:space:]]+)?import[[:space:]]+'"${adapter}"'([[:space:]]|$)' Sources/PositronicKit || true)"; then
        if [[ -n "$matches" ]]; then
            report_failure "PositronicKit imports adapter $adapter:\n$matches"
        fi
    fi
done

# Adapters must never import a provider or another adapter, and must use only
# public API: no package-level access, so they prove the public protocols suffice.
for adapter in $ADAPTERS; do
    if [[ ! -d "Sources/$adapter" ]]; then
        continue
    fi
    for provider in $PROVIDERS; do
        if matches="$(find_matches '^(@_exported[[:space:]]+)?import[[:space:]]+'"${provider}"'([[:space:]]|$)' "Sources/$adapter" || true)"; then
            if [[ -n "$matches" ]]; then
                report_failure "$adapter imports provider $provider:\n$matches"
            fi
        fi
    done
    for other in $ADAPTERS; do
        if [[ "$other" == "$adapter" ]]; then
            continue
        fi
        if matches="$(find_matches '^(@_exported[[:space:]]+)?import[[:space:]]+'"${other}"'([[:space:]]|$)' "Sources/$adapter" || true)"; then
            if [[ -n "$matches" ]]; then
                report_failure "$adapter imports adapter $other:\n$matches"
            fi
        fi
    done
    if matches="$(find_matches '(^|[^A-Za-z0-9_])package[[:space:]]+(func|var|let|class|struct|enum|actor|protocol|extension|typealias|final[[:space:]])' "Sources/$adapter" || true)"; then
        if [[ -n "$matches" ]]; then
            report_failure "$adapter uses package-level symbols (adapters must use only public API):\n$matches"
        fi
    fi
    block="$(target_block "$adapter")"
    if [[ -n "$block" ]]; then
        for provider in $PROVIDERS; do
            if grep -q "\"$provider\"" <<<"$block"; then
                report_failure "$adapter target depends on provider $provider"
            fi
        done
    fi
done

if (( failed != 0 )); then
    exit 1
fi

echo "Dependency direction checks passed."
