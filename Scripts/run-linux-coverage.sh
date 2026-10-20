#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="$repo_root/.build/linux-coverage"
mkdir -p "$output_dir"

# The merged export is only an input to the normalizer, which writes its own
# copy; keep it in a temp file so the uploaded report directory holds one raw
# report instead of two multi-hundred-megabyte JSON files.
merged_report=""
cleanup() {
  if [ -n "$merged_report" ]; then
    rm -f "$merged_report"
  fi
}
trap cleanup EXIT

swiftpm_args=()
if [ -n "${LINUX_COVERAGE_SCRATCH_PATH:-}" ]; then
  swiftpm_args+=(--scratch-path "$LINUX_COVERAGE_SCRATCH_PATH")
fi

# `swiftpm_args` is empty unless a scratch path is set, and `set -u` in Bash
# 3.2 — the macOS system shell — treats "${array[@]}" on an empty array as an
# unbound variable. The `+` form expands to no argument instead of erroring.
echo "Running Linux tests with code coverage..."
swift test ${swiftpm_args[@]+"${swiftpm_args[@]}"} ${SWIFT_BUILD_FLAGS:--Xswiftc -warnings-as-errors} --enable-code-coverage

raw_report="$(swift test ${swiftpm_args[@]+"${swiftpm_args[@]}"} --show-codecov-path)"
if [ ! -s "$raw_report" ]; then
  printf 'Linux coverage report is missing or empty: %s\n' "$raw_report" >&2
  exit 1
fi

# Swift Build, the Swift 6.4 default build system, builds one test runner per
# test target and exports each runner's coverage to the same JSON path, so only
# the last test product survives. A module that is linked into a single test
# product, such as PKObservable, then disappears from the report. Re-export the
# merged profile across every test product bundle in one llvm-cov invocation,
# which is the shape SwiftPM's own post-6.4.0 fix uses, so the report describes
# every product the tests executed.
report="$raw_report"
codecov_dir="$(cd "$(dirname "$raw_report")" && pwd -P)"
products_dir="$(dirname "$codecov_dir")"
profdata="$codecov_dir/default.profdata"
test_runners=("$products_dir"/*-test-runner)
if [ -e "${test_runners[0]}" ]; then
  if [ ! -f "$profdata" ]; then
    printf 'Linux coverage profile is missing: %s\n' "$profdata" >&2
    exit 1
  fi
  if command -v llvm-cov >/dev/null 2>&1; then
    llvm_cov="$(command -v llvm-cov)"
  elif command -v xcrun >/dev/null 2>&1; then
    llvm_cov="$(xcrun --find llvm-cov 2>/dev/null || true)"
  else
    llvm_cov=""
  fi
  if [ -z "$llvm_cov" ] || [ ! -x "$llvm_cov" ]; then
    printf 'Linux coverage merge requires llvm-cov on PATH or through xcrun\n' >&2
    exit 1
  fi
  test_bundles=()
  for runner in "${test_runners[@]}"; do
    [ -e "$runner" ] || continue
    bundle="${runner%-test-runner}.so"
    if [ ! -f "$bundle" ]; then
      bundle="${runner%-test-runner}.xctest"
    fi
    if [ ! -e "$bundle" ]; then
      printf 'Linux coverage bundle is missing for test runner: %s\n' "$runner" >&2
      exit 1
    fi
    test_bundles+=("$bundle")
  done
  if [ "${#test_bundles[@]}" -eq 0 ]; then
    printf 'Linux coverage found no test product bundles in %s\n' "$products_dir" >&2
    exit 1
  fi
  merged_report="$(mktemp "${TMPDIR:-/tmp}/linux-coverage-merged.XXXXXX")"
  merge_args=(export "--instr-profile=$profdata")
  for bundle in "${test_bundles[@]:1}"; do
    merge_args+=(-object "$bundle")
  done
  merge_args+=("${test_bundles[0]}")
  "$llvm_cov" "${merge_args[@]}" > "$merged_report"
  if [ ! -s "$merged_report" ]; then
    printf 'Linux coverage merged report is missing or empty: %s\n' "$merged_report" >&2
    exit 1
  fi
  report="$merged_report"
fi

echo "Normalizing llvm-cov report from $report..."
python3 "$repo_root/Scripts/linux-coverage-report.py" \
  --raw-report "$report" \
  --output-dir "$output_dir" \
  --package-root "$repo_root"
