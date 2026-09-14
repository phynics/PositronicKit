#!/usr/bin/env python3
"""Fail-closed tests for Scripts/migrate-turn-execution-request.py.

The script resolves its repository from its own location, so each case copies
it into a synthetic fixture tree and asserts `--check` exits non-zero on a
flattened TurnEngine call and on a flattened source seam.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/migrate-turn-execution-request.py"

TEST_FILES = (
    "Tests/PKProviderIntegrationTests/Turns/TurnEngineTests.swift",
    "Tests/PKProviderIntegrationTests/Turns/TurnEngineTerminalEventTests.swift",
    "Tests/PKProviderIntegrationTests/Turns/TurnEngineFailurePersistenceTests.swift",
)
SOURCE_GUARDS = (
    "Sources/PositronicKit/Services/Turn/TurnEngine.swift",
    "Sources/PositronicKit/Services/Turn/TurnEngine+TurnPreparation.swift",
    "Sources/PositronicKit/PKRuntime.swift",
)


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    for relative in TEST_FILES:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// migrated fixture\n", encoding="utf-8")
    for relative in SOURCE_GUARDS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// guarded seam fixture\n", encoding="utf-8")
    return scripts / SCRIPT.name


def run_check(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script), "--check"],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        script = make_fixture(Path(directory))
        result = run_check(script)
        assert result.returncode == 0, result.stdout + result.stderr


def test_flattened_call_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        target = root / TEST_FILES[0]
        target.write_text(
            "let outcome = try await engine.execute(timelineID: timelineID, tools: tools, message: message)\n",
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "flattened TurnEngine call(s) remain" in result.stderr, result.stderr


def test_flattened_source_seam_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        seam = root / SOURCE_GUARDS[0]
        seam.write_text(
            "func execute(timelineID: UUID) async throws {}\n",
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "flattened execution interface" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_clean_tree_passes,
        test_flattened_call_is_rejected,
        test_flattened_source_seam_is_rejected,
    ]
    for test in tests:
        test()
    print(f"migrate turn execution request script tests passed ({len(tests)} tests)")
