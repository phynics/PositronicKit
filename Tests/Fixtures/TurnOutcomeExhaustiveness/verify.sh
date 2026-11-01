#!/usr/bin/env bash
set -euo pipefail

fixture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
missing_default_log="$(mktemp)"
scratch="$(mktemp -d)"
trap 'rm -f "$missing_default_log"; rm -rf "$scratch"' EXIT

if swift build -Xswiftc -warnings-as-errors --jobs 1 --package-path "$fixture" --scratch-path "$scratch" >"$missing_default_log" 2>&1; then
  cat "$missing_default_log"
  echo "TurnOutcome exhaustive consumer unexpectedly compiled without @unknown default." >&2
  exit 1
fi

if ! grep -q "may have additional unknown values" "$missing_default_log"; then
  cat "$missing_default_log"
  echo "TurnOutcome consumer failed for a reason other than the missing @unknown default." >&2
  exit 1
fi

echo "Separate-package exhaustive switch failed as expected without @unknown default."
swift build -Xswiftc -warnings-as-errors --jobs 1 --package-path "$fixture" --scratch-path "$scratch" -Xswiftc -DTURN_OUTCOME_UNKNOWN_DEFAULT
echo "Separate-package switch compiled with @unknown default."
swift run --skip-build --package-path "$fixture" --scratch-path "$scratch" TurnOutcomeExhaustiveness
