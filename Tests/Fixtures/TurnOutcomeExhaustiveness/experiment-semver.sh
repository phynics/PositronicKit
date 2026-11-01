#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source_file="$root/Sources/PositronicKit/Services/Database/TimelineRuntimeRepository.swift"
ledger_file="$root/Sources/PositronicKit/Services/Database/TurnLedger.swift"
loop_file="$root/Sources/PositronicKit/Services/Turn/TurnLoop.swift"
finalizer_file="$root/Sources/PositronicKit/Services/Turn/TurnFinalizer.swift"
engine_file="$root/Sources/PositronicKit/Services/Turn/TurnEngine.swift"
reflection_file="$root/Tests/PKTestSupport/TestReflection.swift"
platform="$(uname -s)"
case "$platform" in
  Linux) platform_name=linux ;;
  Darwin) platform_name=macos ;;
  *) echo "Unsupported platform: $platform" >&2; exit 2 ;;
esac
baseline="$root/api/next-public-api-$platform_name.json"
experimental_baseline="$root/api/next-experimental-api-$platform_name.json"
artifact="$root/.build/turn-outcome-semver-experiment"
if ! git -C "$root" diff --quiet -- "$source_file" "$ledger_file" "$loop_file" "$finalizer_file" "$engine_file" "$reflection_file" "$baseline" "$experimental_baseline" || \
   ! git -C "$root" diff --cached --quiet -- "$source_file" "$ledger_file" "$loop_file" "$finalizer_file" "$engine_file" "$reflection_file" "$baseline" "$experimental_baseline"; then
  echo "Experiment requires clean TurnOutcome sources and the platform Next baseline." >&2
  exit 2
fi
mkdir -p "$artifact"
log="$artifact/run.log"
backup_dir="$(mktemp -d)"
cp "$source_file" "$backup_dir/source.swift"
cp "$baseline" "$backup_dir/baseline.json"
cp "$experimental_baseline" "$backup_dir/experimental-baseline.json"
cp "$ledger_file" "$backup_dir/ledger.swift"
cp "$loop_file" "$backup_dir/loop.swift"
cp "$finalizer_file" "$backup_dir/finalizer.swift"
cp "$engine_file" "$backup_dir/engine.swift"
cp "$reflection_file" "$backup_dir/reflection.swift"
restore() {
  cp "$backup_dir/source.swift" "$source_file"
  cp "$backup_dir/ledger.swift" "$ledger_file"
  cp "$backup_dir/loop.swift" "$loop_file"
  cp "$backup_dir/finalizer.swift" "$finalizer_file"
  cp "$backup_dir/engine.swift" "$engine_file"
  cp "$backup_dir/reflection.swift" "$reflection_file"
  cp "$backup_dir/baseline.json" "$baseline"
  cp "$backup_dir/experimental-baseline.json" "$experimental_baseline"
  rm -rf "$backup_dir"
}
trap restore EXIT
exec > >(tee "$log") 2>&1

run_expect() {
  expected_status="$1"
  shift
  echo "+ $*"
  set +e
  "$@"
  status=$?
  set -e
  echo "exit status: $status (expected $expected_status)"
  if [ "$status" -ne "$expected_status" ]; then
    return 1
  fi
}

echo "Temporary actual TurnOutcome case-addition experiment; source and Next baseline are restored on exit."
python3 - "$source_file" "$ledger_file" "$loop_file" "$finalizer_file" "$engine_file" "$reflection_file" <<'PY'
from pathlib import Path
import sys

def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one temporary edit anchor in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1))

source, ledger, loop, finalizer, engine, reflection = map(Path, sys.argv[1:])
replace(source,
    "    case interrupted(reason: String)\n",
    "    case interrupted(reason: String)\n    case limitReached(reason: String)\n")
replace(source, "case completed, failed, cancelled, interrupted\n",
    "case completed, failed, cancelled, interrupted, limitReached\n")
replace(source,
    "        case let .interrupted(reason):\n            try container.encode(Kind.interrupted, forKey: .kind)\n            try container.encode(reason, forKey: .reason)\n",
    "        case let .interrupted(reason):\n            try container.encode(Kind.interrupted, forKey: .kind)\n            try container.encode(reason, forKey: .reason)\n        case let .limitReached(reason):\n            try container.encode(Kind.limitReached, forKey: .kind)\n            try container.encode(reason, forKey: .reason)\n")
replace(source,
    "        case .interrupted:\n            self = .interrupted(reason: try container.decode(String.self, forKey: .reason))\n",
    "        case .interrupted:\n            self = .interrupted(reason: try container.decode(String.self, forKey: .reason))\n        case .limitReached:\n            self = .limitReached(reason: try container.decode(String.self, forKey: .reason))\n")
replace(ledger,
    "        case .interrupted: return .interrupted\n",
    "        case .interrupted: return .interrupted\n        case .limitReached: return .failed\n")
replace(ledger,
    "        case let .interrupted(reason): return \"interrupted: \\(reason)\"\n",
    "        case let .interrupted(reason): return \"interrupted: \\(reason)\"\n        case let .limitReached(reason): return \"limit reached: \\(reason)\"\n")
replace(loop,
    "        case .interrupted:\n            finalMessage = .none\n",
    "        case .interrupted:\n            finalMessage = .none\n        case .limitReached:\n            finalMessage = .partialAssistant(await PartialAssistantSource.capture(from: context))\n")
replace(finalizer,
    "        case .failed, .interrupted:\n            return .turnFailed\n",
    "        case .failed, .interrupted, .limitReached:\n            return .turnFailed\n")
replace(finalizer,
    "        case let .interrupted(reason):\n            return reason\n",
    "        case let .interrupted(reason):\n            return reason\n        case let .limitReached(reason):\n            return reason\n")
replace(finalizer,
    "        case let .interrupted(reason):\n            return .event(.error(reason))\n",
    "        case let .interrupted(reason):\n            return .event(.error(reason))\n        case let .limitReached(reason):\n            return .event(.error(reason))\n")
replace(engine,
    "                case let .interrupted(reason):\n                    continuation.yield(.error(reason))\n",
    "                case let .interrupted(reason):\n                    continuation.yield(.error(reason))\n                case let .limitReached(reason):\n                    continuation.yield(.error(reason))\n")
replace(reflection,
    "        case let .interrupted(reason):\n            Mirror(self, children: [(label: \"interrupted\", value: reason)])\n",
    "        case let .interrupted(reason):\n            Mirror(self, children: [(label: \"interrupted\", value: reason)])\n        case let .limitReached(reason):\n            Mirror(self, children: [(label: \"limitReached\", value: reason)])\n")
PY

run_expect 2 make verify-public-api
if ! grep -q 'added: PositronicKit.TurnOutcome/limitReached(reason:)' "$log"; then
  echo "API check did not identify the real added TurnOutcome case." >&2
  exit 1
fi

run_expect 0 python3 Scripts/public-api-baseline.py --write
echo "+ python3 real generated API surfaces through the release semver gate"
set +e
python3 - "$root" "$backup_dir/baseline.json" "$baseline" "$platform_name" <<'PY'
import json
import importlib.util
import pathlib
import shutil
import sys
import tempfile

root, previous_path, candidate_path = map(pathlib.Path, sys.argv[1:4])
platform = sys.argv[4]
with tempfile.TemporaryDirectory(prefix="turn-outcome-semver-") as temporary:
    fixture = pathlib.Path(temporary)
    (fixture / "Scripts").mkdir()
    (fixture / "docs").mkdir()
    (fixture / "api").mkdir()
    shutil.copy(root / "Scripts/validate-release-readiness.py", fixture / "Scripts/")
    catalog = json.loads((root / "docs/catalog.json").read_text())
    catalog["stable"] = {"version": "7.1.0", "ref": "7.1.0"}
    (fixture / "docs/catalog.json").write_text(json.dumps(catalog))
    changelog = """# Changelog

## [Unreleased]

## [7.1.0] - 2026-11-01

### Added

- Add the experimental TurnOutcome.limitReached case.

## [7.0.0] - 2026-10-20

### Breaking

- PositronicKit 7.0.0.
"""
    (fixture / "CHANGELOG.md").write_text(changelog)
    for version, source in (("7.0", previous_path), ("7.1", candidate_path)):
        api = json.loads(source.read_text())
        api["release"] = version
        api["platform"] = platform
        (fixture / "api" / f"{version}-public-api-{platform}.json").write_text(
            json.dumps(api, indent=2) + "\n"
        )
    script = fixture / "Scripts/validate-release-readiness.py"
    spec = importlib.util.spec_from_file_location("release_readiness", script)
    if spec is None or spec.loader is None:
        raise SystemExit("failed to load the repository release-readiness gate")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    violations = module.api_semver_violations(
        fixture, "7.1.0", changelog, platforms=(platform,)
    )
    print(
        "+ validate-release-readiness.api_semver_violations("
        f"version='7.1.0', platforms=({platform!r},))"
    )
    for violation in violations:
        print(f"  {violation}")
    print(f"exit status: {1 if violations else 0} (expected 0)")
    raise SystemExit(1 if violations else 0)
PY
gate_status=$?
set -e
if [ "$gate_status" -ne 0 ]; then
  echo "The actual generated API case addition failed the 7.1 semver gate." >&2
  exit "$gate_status"
fi
cp "$backup_dir/baseline.json" "$baseline"
echo "Restored current source and $baseline. Full log: $log"
