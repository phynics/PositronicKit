#!/usr/bin/env bash
set -euo pipefail

# Enforces that the pinned MiniLM artifact identity stays in sync across every
# place it is declared, so the pin can never silently drift:
#   - Packages/PKFastEmbed/model-assets.sha256          (per-file SHA-256, shell/CI pin)
#   - Sources/PKLocalEmbeddings/MiniLMModelAssets.swift (per-file SHA-256 + revision, runtime pin)
#   - Scripts/bootstrap-minilm-ci.sh                    (download revision)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/Packages/PKFastEmbed/model-assets.sha256"
swift="$repo_root/Sources/PKLocalEmbeddings/MiniLMModelAssets.swift"
bootstrap="$repo_root/Scripts/bootstrap-minilm-ci.sh"

fail() {
  echo "model pin check FAILED: $1" >&2
  exit 1
}

for file in "$manifest" "$swift" "$bootstrap"; do
  [[ -f "$file" ]] || fail "missing $file"
done

# 1. The download revision must match between the Swift runtime pin and the bootstrap script.
swift_rev="$(grep -E 'static let revision' "$swift" | sed -E 's/.*"([0-9a-fA-F]+)".*/\1/')"
boot_rev="$(grep -E '^revision=' "$bootstrap" | sed -E 's/.*"([0-9a-fA-F]+)".*/\1/')"
[[ -n "$swift_rev" ]] || fail "could not parse revision from $swift"
[[ "$swift_rev" == "$boot_rev" ]] || fail "revision mismatch: Swift=$swift_rev bootstrap=$boot_rev"

# 2. The per-file SHA-256 set must match between the manifest and the Swift pin (order-independent).
normalize_manifest() {
  awk 'NF>=2 {print $2" "$1}' "$manifest" | sort
}
normalize_swift() {
  grep -E '"[^"]+": "[0-9a-f]{64}"' "$swift" \
    | sed -E 's/.*"([^"]+)": "([0-9a-f]{64})".*/\1 \2/' | sort
}

if ! diff <(normalize_manifest) <(normalize_swift) >/dev/null; then
  echo "----- model-assets.sha256 (file sha256) -----" >&2
  normalize_manifest >&2
  echo "----- MiniLMModelAssets.swift (file sha256) -----" >&2
  normalize_swift >&2
  fail "per-file checksum set differs between model-assets.sha256 and MiniLMModelAssets.swift"
fi

file_count="$(normalize_manifest | wc -l | tr -d ' ')"
echo "model pin OK: revision $swift_rev, $file_count files consistent across manifest, Swift, and bootstrap"
