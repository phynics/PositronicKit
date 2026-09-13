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

while IFS= read -r file; do
    report_failure "$(basename "$file") sits directly in Tests/PositronicKitTests/; move it into a domain subtree"
done < <(find Tests/PositronicKitTests -maxdepth 1 -name '*.swift' -print 2>/dev/null)

while IFS= read -r path; do
    basename=${path##*/}
    if printf '%s\n' "$basename" | grep -qiE '(stab|ticket)[0-9_-]*[0-9]|issue-[0-9]+'; then
        report_failure "$path carries a ticket identifier in its filename; rename it to describe the behavior"
    fi
done < <(find Tests -name '*.swift' -print 2>/dev/null)

if (( failed != 0 )); then
    exit 1
fi

echo "Test layout checks passed."
