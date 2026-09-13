#!/usr/bin/env python3
"""Fail-closed tests for Scripts/validate-release-readiness.py.

The script operates on the real checkout (catalog, changelog, git tags), so
these cases pin the side-effect-free rejection paths: malformed input and a
version the catalog does not declare. The positive direction runs in
`make verify-release` during publication, which requires an annotated tag on
a clean tree.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/validate-release-readiness.py"


def run_gate(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(SCRIPT), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_missing_version_is_rejected() -> None:
    result = run_gate()
    assert result.returncode == 1, result.stdout + result.stderr
    assert "bare semantic version" in result.stderr, result.stderr


def test_malformed_version_is_rejected() -> None:
    result = run_gate("5.1")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "bare semantic version" in result.stderr, result.stderr


def test_undeclared_version_is_rejected() -> None:
    result = run_gate("0.0.0")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "stable.version and stable.ref must both equal 0.0.0" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_missing_version_is_rejected,
        test_malformed_version_is_rejected,
        test_undeclared_version_is_rejected,
    ]
    for test in tests:
        test()
    print(f"release readiness script tests passed ({len(tests)} tests)")
