#!/usr/bin/env bash
# check-test-layout.sh — enforce the runtime test-target file layout.
#
# The PositronicKitTests target keeps its suites in domain subtrees (Services/,
# Models/, Stories/, InternalStories/, ...). Files sitting flat in the target
# root and ticket identifiers leaking into filenames both defeat that
# organization, so this gate fails closed on either condition.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failed=0

report_failure() {
    printf 'test-layout: %s\n' "$1" >&2
    failed=1
}

for target in Tests/PositronicKitTests Tests/PKProviderIntegrationTests; do
    if [[ ! -d "$target" ]]; then
        report_failure "$target is missing; test-target layout cannot be checked"
        continue
    fi
    while IFS= read -r file; do
        report_failure "$(basename "$file") sits directly in $target/; move it into a domain subtree"
    done < <(find "$target" -maxdepth 1 -name '*.swift' -print)
done

runtime_tags="Tests/PositronicKitTests/Support/TestTags.swift"
provider_tags="Tests/PKProviderIntegrationTests/Support/TestTags.swift"
if [[ ! -f "$runtime_tags" || ! -f "$provider_tags" ]]; then
    report_failure "both runtime test targets must define synchronized TestTags.swift files"
else
    runtime_tag_declarations="$(grep -E '^[[:space:]]*@Tag static var (unit|integration|slow|platformSpecific|generative)' "$runtime_tags" || true)"
    provider_tag_declarations="$(grep -E '^[[:space:]]*@Tag static var (unit|integration|slow|platformSpecific|generative)' "$provider_tags" || true)"
    if [[ -z "$runtime_tag_declarations" || "$runtime_tag_declarations" != "$provider_tag_declarations" ]]; then
        report_failure "runtime test target tag definitions differ between $runtime_tags and $provider_tags"
    fi
fi

while IFS= read -r path; do
    basename=${path##*/}
    if printf '%s\n' "$basename" | grep -qiE '(stab|ticket)[0-9_-]*[0-9]|issue-[0-9]+'; then
        report_failure "$path carries a ticket identifier in its filename; rename it to describe the behavior"
    fi
done < <(find Tests -name '*.swift' -print 2>/dev/null)

# New Turn tests build through the deep TestRuntime fixture so construction wiring has one home
# and the 7.0 internal refactors do not break suites that only meant to test behavior. The
# grandfather list may only shrink: a stale entry fails the gate.
test_runtime_fixture="Tests/PKTestSupport/TestRuntime.swift"
runtime_allowlist="Scripts/test-runtime-allowlist.txt"
if [[ ! -f "$test_runtime_fixture" ]]; then
    report_failure "$test_runtime_fixture is missing; Turn tests have no deep fixture"
fi
if [[ ! -f "$runtime_allowlist" ]]; then
    report_failure "$runtime_allowlist is missing; inline PKRuntime construction cannot be checked"
fi

if [[ -f "$runtime_allowlist" ]]; then
    while IFS= read -r path; do
        [[ -z "$path" || "$path" == \#* ]] && continue
        if [[ ! -f "$path" ]]; then
            report_failure "$runtime_allowlist names $path, which does not exist; remove the stale entry"
            continue
        fi
        if ! grep -qE '(^|[^A-Za-z0-9_.])PKRuntime\(' "$path"; then
            report_failure "$runtime_allowlist names $path, but it no longer builds a PKRuntime inline; remove the stale entry"
        fi
    done < "$runtime_allowlist"
fi

while IFS= read -r turn_dir; do
    while IFS= read -r path; do
        if ! grep -qE '(^|[^A-Za-z0-9_.])PKRuntime\(' "$path"; then
            continue
        fi
        if [[ -f "$runtime_allowlist" ]] && grep -qxF "$path" "$runtime_allowlist"; then
            continue
        fi
        report_failure "$path builds PKRuntime inline; build through TestRuntime instead"
    done < <(find "$turn_dir" -maxdepth 1 -name '*.swift' -print)
done < <(find Tests -type d -name Turns -print 2>/dev/null)

if (( failed != 0 )); then
    exit 1
fi

echo "Test layout checks passed."
