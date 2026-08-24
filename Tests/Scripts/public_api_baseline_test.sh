#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/fixture"
fake_bin="$tmp_dir/bin"
mkdir -p "$fixture/Scripts" "$fixture/docs" "$fixture/api" "$fake_bin"
cp "$repo_root/Scripts/public-api-baseline.py" "$fixture/Scripts/"
cp "$repo_root/docs/catalog.json" "$fixture/docs/"

cat > "$fixture/api/4.0-public-api-linux.json" <<'EOF'
{
  "schemaVersion": 2,
  "release": "4.0",
  "platform": "linux",
  "modules": [
    "PKAnthropicProvider",
    "PKContracts",
    "PKFoundationModelsProvider",
    "PKObservable",
    "PKOllamaProvider",
    "PKOpenAIProvider",
    "PKOpenRouterProvider",
    "PKPrompt",
    "PKTestSupport",
    "PositronicKit"
  ],
  "symbols": [],
  "relationships": []
}
EOF

cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture="${PUBLIC_API_FIXTURE:?PUBLIC_API_FIXTURE is required}"
if [ "${1:-}" = "build" ] && [ "${2:-}" = "--show-bin-path" ]; then
  printf '%s\n' "$fixture/.build/x86_64-unknown-linux-gnu/debug"
  exit 0
fi

if [ "${1:-}" = "package" ] && [ "${2:-}" = "dump-symbol-graph" ]; then
  output_dir=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "--output-dir" ]; then
      output_dir="$argument"
      break
    fi
    previous="$argument"
  done
  if [ -z "$output_dir" ]; then
    output_dir="$fixture/.build/x86_64-unknown-linux-gnu/symbolgraph"
  fi
  mkdir -p "$output_dir"
  for module in \
    PKAnthropicProvider PKContracts PKFoundationModelsProvider PKObservable \
    PKOllamaProvider PKOpenAIProvider PKOpenRouterProvider PKPrompt \
    PKTestSupport PositronicKit; do
    if [ "${OMIT_MODULE:-}" = "$module" ]; then
      continue
    fi
    printf '{"module":{"name":"%s"},"symbols":[],"relationships":[]}\n' "$module" \
      > "$output_dir/$module.symbols.json"
  done
  printf 'Files written to %s\n' "$output_dir"
  exit 0
fi

printf 'unexpected swift arguments: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$fake_bin/swift"

run_baseline() {
  env PATH="$fake_bin:$PATH" PUBLIC_API_FIXTURE="$fixture" OMIT_MODULE="${OMIT_MODULE:-}" \
    python3 "$fixture/Scripts/public-api-baseline.py" --check
}

run_baseline > "$tmp_dir/success.log"
success_output="$(<"$tmp_dir/success.log")"
if [[ "$success_output" != *'Public API matches'* ]]; then
  printf 'FAIL: expected symbol graphs in SwiftPM output directory\n' >&2
  printf '%s\n' "$success_output" >&2
  exit 1
fi
printf 'ok: uses explicit SwiftPM symbol-graph output directory\n'

if OMIT_MODULE=PKPrompt run_baseline > "$tmp_dir/missing.log" 2>&1; then
  printf 'FAIL: expected a missing symbol graph to fail\n' >&2
  exit 1
fi
missing_output="$(<"$tmp_dir/missing.log")"
if [[ "$missing_output" != *'missing public symbol graphs: PKPrompt'* ]]; then
  printf 'FAIL: missing graph diagnostic was not reported\n' >&2
  printf '%s\n' "$missing_output" >&2
  exit 1
fi
printf 'ok: rejects an omitted public symbol graph\n'
