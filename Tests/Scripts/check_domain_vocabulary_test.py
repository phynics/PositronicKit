#!/usr/bin/env python3
"""Fail-closed tests for Scripts/check-domain-vocabulary.sh.

Copies the gate script and its allowlist into a synthetic fixture tree (the
script resolves the repository from its own location) and asserts retired
vocabulary in file contents and in filenames exits non-zero, while a clean
tree passes.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-domain-vocabulary.sh"
ALLOWLIST = ROOT / "Scripts/domain-vocabulary-allowlist.txt"

CHANGELOG = """# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01
"""


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    shutil.copyfile(ALLOWLIST, scripts / ALLOWLIST.name)
    for directory in ("Sources", "Tests", "docs", ".github"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    for name in ("README.md", "AGENTS.md", "CONTEXT-MAP.md", "Package.swift", "llms.txt"):
        (root / name).write_text("# Fixture\n", encoding="utf-8")
    (root / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
    timeline_handle = root / "Sources/PositronicKit/Timelines/TimelineHandle.swift"
    timeline_handle.parent.mkdir(parents=True, exist_ok=True)
    timeline_handle.write_text(
        "public func startTurn() {}\npublic func startDirectTurn() {}\n",
        encoding="utf-8",
    )
    return scripts / SCRIPT.name


def run_gate(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "Sources/Runtime.swift").write_text("public struct Turn {}\n", encoding="utf-8")
        result = run_gate(script)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "domain vocabulary check passed" in result.stdout, result.stdout


def test_retired_content_term_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        retired_type = "Chat" + "Engine"
        (root / "Sources/Runtime.swift").write_text(f"let engine = {retired_type}()\n", encoding="utf-8")
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "domain vocabulary check failed" in result.stderr, result.stderr


def test_retired_filename_term_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        retired_type = "Chat" + "Engine"
        retired_name = retired_type + ".swift"
        (root / f"Sources/{retired_name}").write_text(
            f"public struct {retired_type} {{}}\n", encoding="utf-8"
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert retired_name in result.stderr, result.stderr


def test_selective_first_party_import_is_rejected() -> None:
    """#156's acceptance criterion: no file may disambiguate a PositronicKit
    type from a platform type with a selective submodule import."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "Tests/ConsumerTests.swift").write_text(
            "import Foundation\nimport struct PositronicKit.TimelineRecord\n",
            encoding="utf-8",
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "selective-import" in result.stderr, result.stderr


def test_selective_third_party_import_is_allowed() -> None:
    """JSONSchema.Schema is an upstream type, not a collision workaround."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "Sources/Tool.swift").write_text(
            "import Foundation\nimport struct JSONSchema.Schema\n",
            encoding="utf-8",
        )
        result = run_gate(script)
        assert result.returncode == 0, result.stdout + result.stderr


def test_duplicate_timeline_entry_point_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        timeline_handle = root / "Sources/PositronicKit/Timelines/TimelineHandle.swift"
        timeline_handle.write_text(
            "public func startTurn() {}\nfunc send(_ message: String) {}\n",
            encoding="utf-8",
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "duplicate-entry-point" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_clean_tree_passes,
        test_retired_content_term_is_rejected,
        test_retired_filename_term_is_rejected,
        test_duplicate_timeline_entry_point_is_rejected,
        test_selective_first_party_import_is_rejected,
        test_selective_third_party_import_is_allowed,
    ]
    for test in tests:
        test()
    print(f"domain vocabulary script tests passed ({len(tests)} tests)")
