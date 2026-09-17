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
baseline_release="$(python3 -c "import json; print('.'.join(json.load(open('$fixture/docs/catalog.json'))['next']['version'].split('.')[:2]))")"

cat > "$fixture/api/$baseline_release-public-api-linux.json" <<EOF
{
  "schemaVersion": 2,
  "release": "$baseline_release",
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

# The gate selects its baseline by host platform, so the fixture needs both;
# otherwise the macOS run fails on a missing baseline before comparing graphs.
sed 's/"platform": "linux"/"platform": "macos"/' \
  "$fixture/api/$baseline_release-public-api-linux.json" \
  > "$fixture/api/$baseline_release-public-api-macos.json"

cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture="${PUBLIC_API_FIXTURE:?PUBLIC_API_FIXTURE is required}"
if [ "${1:-}" = "build" ] && [ "${2:-}" = "--show-bin-path" ]; then
  printf '%s\n' "$fixture/.build/x86_64-unknown-linux-gnu/debug"
  exit 0
fi

if [ "${1:-}" = "package" ] && [ "${2:-}" = "dump-symbol-graph" ]; then
  output_dir="$fixture/.build/x86_64-unknown-linux-gnu/symbolgraph"
  bin_dir="$fixture/.build/x86_64-unknown-linux-gnu/debug"
  mkdir -p "$output_dir" "$bin_dir"
  for module in \
    PKAnthropicProvider PKContracts PKFoundationModelsProvider PKObservable \
    PKOllamaProvider PKOpenAIProvider PKOpenRouterProvider PKPrompt \
    PKTestSupport PositronicKit; do
    if [ "${OMIT_MODULE:-}" = "$module" ]; then
      continue
    fi
    printf '{"module":{"name":"%s"},"symbols":[],"relationships":[]}\n' "$module" \
      > "$output_dir/$module.symbols.json"
    # A compiled module accompanies every emitted graph. The gate only
    # attempts its Darwin fallback extraction where a .swiftmodule exists,
    # so the stub keeps the fixture faithful on both platforms.
    : > "$bin_dir/$module.swiftmodule"
  done
  printf 'Files written to %s\n' "$output_dir"
  exit "${DUMP_STATUS:-0}"
fi

printf 'unexpected swift arguments: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$fake_bin/swift"

# Hermetic stand-in for the Xcode toolchain pieces the baseline gate invokes
# on Darwin: `--show-sdk-path` and `swift-symbolgraph-extract`. It regenerates
# the requested module graph unless the module is deliberately omitted, which
# keeps the missing-graph rejection meaningful on macOS. Linux runs never
# reach for xcrun, so behavior there is unchanged.
cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--show-sdk-path" ]; then
  printf '%s\n' "${FAKE_SDK_PATH:?FAKE_SDK_PATH is required}"
  exit 0
fi

if [ "${1:-}" = "swift-symbolgraph-extract" ]; then
  module=""
  output_dir=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "-module-name" ]; then
      module="$argument"
    fi
    if [ "$previous" = "-output-dir" ]; then
      output_dir="$argument"
    fi
    previous="$argument"
  done
  if [ -z "$module" ] || [ -z "$output_dir" ]; then
    printf 'swift-symbolgraph-extract mock needs -module-name and -output-dir\n' >&2
    exit 2
  fi
  if [ "$module" = "${OMIT_MODULE:-}" ]; then
    exit 0
  fi
  printf '{"module":{"name":"%s"},"symbols":[],"relationships":[]}\n' "$module" \
    > "$output_dir/$module.symbols.json"
  exit 0
fi

printf 'unexpected xcrun arguments: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$fake_bin/xcrun"

run_baseline() {
  env PATH="$fake_bin:$PATH" PUBLIC_API_FIXTURE="$fixture" OMIT_MODULE="${OMIT_MODULE:-}" \
    FAKE_SDK_PATH="$fixture/SDKs/MacOSX.sdk" \
    python3 "$fixture/Scripts/public-api-baseline.py" --check
}

run_baseline > "$tmp_dir/success.log"
success_output="$(<"$tmp_dir/success.log")"
host_platform="$(python3 -c "import platform; print('macos' if platform.system() == 'Darwin' else 'linux')")"
if [[ "$success_output" != *'Public API matches'* ]]; then
  printf 'FAIL: expected symbol graphs in SwiftPM output directory\n' >&2
  printf '%s\n' "$success_output" >&2
  exit 1
fi
if [[ "$success_output" != *"$baseline_release-public-api-$host_platform.json"* ]]; then
  printf 'FAIL: expected the primary baseline\n' >&2
  printf '%s\n' "$success_output" >&2
  exit 1
fi
printf 'ok: uses reported SwiftPM symbol-graph output directory\n'

DUMP_STATUS=1 run_baseline > "$tmp_dir/nonzero.log" 2> "$tmp_dir/nonzero-error.log"
nonzero_output="$(<"$tmp_dir/nonzero.log")"
nonzero_error="$(<"$tmp_dir/nonzero-error.log")"
if [[ "$nonzero_output" != *'Public API matches'* ]]; then
  printf 'FAIL: expected complete public graphs to tolerate unrelated extraction errors\n' >&2
  printf '%s\n' "$nonzero_output" >&2
  exit 1
fi
if [[ "$nonzero_error" != *'exit status 1'* || "$nonzero_error" != *'reported non-public-target errors'* ]]; then
  printf 'FAIL: expected the extraction status to be recorded\n' >&2
  printf '%s\n' "$nonzero_error" >&2
  exit 1
fi
printf 'ok: tolerates nonzero extraction status when catalog graphs are complete\n'

if OMIT_MODULE=PKPrompt DUMP_STATUS=1 run_baseline > "$tmp_dir/missing.log" 2>&1; then
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
