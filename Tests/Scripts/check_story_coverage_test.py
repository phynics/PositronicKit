#!/usr/bin/env python3
"""Fail-closed tests for Scripts/check-story-coverage.py.

Copies the gate script into a synthetic fixture tree (it resolves the story
roots from its own location) and asserts an unmapped story suite and a stale
index reference both exit non-zero, while a fully mapped tree passes.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-story-coverage.py"


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    stories = root / "Tests/PositronicKitTests/Stories/Runtime"
    stories.mkdir(parents=True, exist_ok=True)
    (stories / "PublicRuntimeStoriesTests.swift").write_text(
        "import Testing\nstruct PublicRuntimeStoriesTests {}\n", encoding="utf-8"
    )
    index = root / "Tests/PositronicKitTests/Stories/StoryCoverageIndex.swift"
    index.write_text(
        "/// - one-turn chat through the facade -> `PublicRuntimeStoriesTests`\n"
        "enum StoryCoverageIndex {}\n",
        encoding="utf-8",
    )
    return scripts / SCRIPT.name


def run_gate(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_mapped_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        script = make_fixture(Path(directory))
        result = run_gate(script)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "maps 1 story suites" in result.stdout, result.stdout


def test_unmapped_suite_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        extra = root / "Tests/PositronicKitTests/InternalStories"
        extra.mkdir(parents=True, exist_ok=True)
        (extra / "ForgottenStoriesTests.swift").write_text(
            "import Testing\nstruct ForgottenStoriesTests {}\n", encoding="utf-8"
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "ForgottenStoriesTests is not mapped" in result.stderr, result.stderr


def test_stale_reference_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        index = root / "Tests/PositronicKitTests/Stories/StoryCoverageIndex.swift"
        index.write_text(
            "/// - one-turn chat -> `PublicRuntimeStoriesTests`\n"
            "/// - retired story -> `DeletedStoriesTests`\n"
            "enum StoryCoverageIndex {}\n",
            encoding="utf-8",
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "DeletedStoriesTests, which no longer exists" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_mapped_tree_passes,
        test_unmapped_suite_is_rejected,
        test_stale_reference_is_rejected,
    ]
    for test in tests:
        test()
    print(f"story coverage script tests passed ({len(tests)} tests)")
