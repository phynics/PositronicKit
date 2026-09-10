#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="${LINUX_COVERAGE_OUTPUT_DIR:-$repo_root/.build/linux-coverage}"
mkdir -p "$output_dir"

swiftpm_args=()
if [ -n "${LINUX_COVERAGE_SCRATCH_PATH:-}" ]; then
  swiftpm_args+=(--scratch-path "$LINUX_COVERAGE_SCRATCH_PATH")
fi

echo "Running Linux tests with code coverage..."
swift test "${swiftpm_args[@]}" ${SWIFT_BUILD_FLAGS:--Xswiftc -warnings-as-errors} --enable-code-coverage

raw_report="$(swift test "${swiftpm_args[@]}" --show-codecov-path)"
if [ ! -s "$raw_report" ]; then
  printf 'Linux coverage report is missing or empty: %s\n' "$raw_report" >&2
  exit 1
fi

echo "Normalizing llvm-cov report from $raw_report..."
python3 "$repo_root/Scripts/linux-coverage-report.py" \
  --raw-report "$raw_report" \
  --output-dir "$output_dir" \
  --package-root "$repo_root"
