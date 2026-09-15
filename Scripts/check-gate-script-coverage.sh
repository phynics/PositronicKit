#!/usr/bin/env bash
# check-gate-script-coverage.sh — keep every gate script under test.
#
# The gate scripts are regex- and awk-based, so a pattern that silently stops
# matching after a refactor turns a gate into a no-op that still reports
# success. The repository answers that with a fixture test per script, and
# this gate keeps that answer honest: a new script in Scripts/ with no test,
# or a test in Tests/Scripts/ that no Makefile target runs, fails the build
# instead of quietly shrinking the harness.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

harness_target="verify-agent-harness"
failed=0

report_failure() {
    printf 'gate-script-coverage: %s\n' "$1" >&2
    failed=1
}

if [[ ! -d Scripts || ! -d Tests/Scripts ]]; then
    report_failure "Scripts/ and Tests/Scripts/ must both exist"
    exit 1
fi

# The recipe lines of the harness target: every line from the target header up
# to the first line that is neither a recipe nor blank.
harness_recipe="$(awk -v target="^${harness_target}:" '
    $0 ~ target { collecting = 1; next }
    collecting && /^\t/ { print; next }
    collecting && /^[[:space:]]*$/ { next }
    collecting { exit }
' Makefile)"

if [[ -z "$harness_recipe" ]]; then
    report_failure "Makefile target $harness_target has no recipe; the script tests would not run"
    exit 1
fi

# Every script must be named by at least one test file.
while IFS= read -r script; do
    name="${script##*/}"
    if ! grep -rqF -- "$name" Tests/Scripts/; then
        report_failure "$script has no test under Tests/Scripts/; add a known-bad fixture test for it"
    fi
done < <(find Scripts -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.swift' \) -print | sort)

# Every test must be run by the harness target.
while IFS= read -r test_file; do
    name="${test_file##*/}"
    if ! printf '%s\n' "$harness_recipe" | grep -qF -- "Tests/Scripts/$name"; then
        report_failure "$test_file is not run by the $harness_target target"
    fi
done < <(find Tests/Scripts -maxdepth 1 -type f \( -name '*_test.sh' -o -name '*_test.py' \) -print | sort)

# The harness must not name a test that no longer exists.
while IFS= read -r referenced; do
    if [[ ! -f "$referenced" ]]; then
        report_failure "$harness_target runs $referenced, which does not exist"
    fi
done < <(printf '%s\n' "$harness_recipe" | grep -oE 'Tests/Scripts/[A-Za-z0-9_.-]+' | sort -u)

if (( failed != 0 )); then
    exit 1
fi

echo "Gate script coverage checks passed."
