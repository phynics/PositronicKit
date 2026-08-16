#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift test ${SWIFT_BUILD_FLAGS:--Xswiftc -warnings-as-errors} --filter 'RuntimeSetupStoriesTests|ExampleUsageStoriesTests|IntroductoryStoriesTests|PublicRuntimeStoriesTests'
bash "$ROOT/Scripts/validate-docc.sh"

# Documentation authority contracts.
# Each tracked documentation artifact has exactly one authority:
#   - authored: hand-maintained source validated by a structural check
#   - generated: produced by a named generator validated by a reproducibility diff
# docs/index.html and llms.txt are both authored (no generator exists).

# docs/index.html — authored GitHub Pages landing page (no generator).
# Authority: hand-maintained since commit 12b1164 ("No build step").
# Validation: non-empty, and its SwiftPM version pin matches README.md.
if [[ ! -s docs/index.html ]]; then
  echo "FAIL: docs/index.html is missing or empty" >&2
  exit 1
fi
readme_pin=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' README.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ -z "$readme_pin" ]]; then
  echo "FAIL: README.md has no SwiftPM version pin" >&2
  exit 1
fi
if ! grep -q "from:.*\"$readme_pin\"" docs/index.html; then
  echo "FAIL: docs/index.html version pin does not match README.md (expected $readme_pin)" >&2
  exit 1
fi
echo "OK: docs/index.html — authored, version pin matches README.md ($readme_pin)"

# llms.txt — authored llmstxt.org-style navigation index (no generator).
# Authority: hand-curated since commit 39d30bc.
# Validation: non-empty, and every relative path in its markdown links resolves.
if [[ ! -s llms.txt ]]; then
  echo "FAIL: llms.txt is missing or empty" >&2
  exit 1
fi
missing_paths=0
while IFS= read -r path; do
  path="${path%%#*}"
  [[ "$path" == http* || -z "$path" ]] && continue
  if [[ ! -e "$path" ]]; then
    echo "FAIL: llms.txt references missing path: $path" >&2
    missing_paths=1
  fi
done < <(grep -oE '\]\([^)]+\)' llms.txt | sed 's/^\](//; s/)$//')
if [[ $missing_paths -ne 0 ]]; then
  exit 1
fi
echo "OK: llms.txt — authored, all referenced paths exist"
