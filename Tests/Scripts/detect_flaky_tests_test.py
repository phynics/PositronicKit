#!/usr/bin/env python3
"""Fixture test for Scripts/detect-flaky-tests.py (issue #155 nightly job)."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "detect-flaky-tests.py"


def write_xunit(path: Path, cases: list[tuple[str, str, str]]) -> None:
    body = ['<?xml version="1.0" encoding="UTF-8"?>', "<testsuites>"]
    for classname, name, outcome in cases:
        body.append(f'<testcase classname="{classname}" name="{name}">')
        if outcome == "failed":
            body.append('<failure message="boom"/>')
        elif outcome == "skipped":
            body.append('<skipped message="unavailable on this platform"/>')
        body.append("</testcase>")
    body.append("</testsuites>")
    path.write_text("\n".join(body), encoding="utf-8")


def run_report(files: list[Path]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--report", *[str(f) for f in files]],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)

        # All-green across iterations: exit 0, no flakes named.
        first = root / "iter-1.xml"
        second = root / "iter-2.xml"
        write_xunit(first, [("SuiteA", "testOne", "passed"), ("SuiteA", "testTwo", "passed")])
        write_xunit(second, [("SuiteA", "testOne", "passed"), ("SuiteA", "testTwo", "passed")])
        result = run_report([first, second])
        assert result.returncode == 0, result.stdout
        assert "All tests passed every iteration." in result.stdout, result.stdout

        # One flaky (fails 1/2) and one consistently failing (2/2): exit 1, both
        # reported by name with failing iteration counts.
        third = root / "iter-3.xml"
        fourth = root / "iter-4.xml"
        write_xunit(third, [("SuiteA", "flakyOne", "failed"), ("SuiteB", "alwaysRed", "failed")])
        write_xunit(fourth, [("SuiteA", "flakyOne", "passed"), ("SuiteB", "alwaysRed", "failed")])
        result = run_report([third, fourth])
        assert result.returncode == 1, result.stdout
        assert "SuiteA.flakyOne: failed 1/2 iterations" in result.stdout, result.stdout
        assert "SuiteB.alwaysRed: failed 2/2 iterations" in result.stdout, result.stdout

        # A test skipped on every iteration is a deterministic platform gate, not a
        # failure: exit 0, listed under its own section, never under "failing".
        gated_first = root / "iter-gated-1.xml"
        gated_second = root / "iter-gated-2.xml"
        write_xunit(gated_first, [("SuiteC", "platformGated", "skipped"), ("SuiteC", "green", "passed")])
        write_xunit(gated_second, [("SuiteC", "platformGated", "skipped"), ("SuiteC", "green", "passed")])
        result = run_report([gated_first, gated_second])
        assert result.returncode == 0, result.stdout
        assert "Skipped on this platform: 1" in result.stdout, result.stdout
        assert "Consistently failing tests: 0" in result.stdout, result.stdout
        assert "SuiteC.platformGated: skipped 2/2 iterations" in result.stdout, result.stdout

        # An intermittent skip — skipped once, passed once — is still a red signal.
        intermittent_first = root / "iter-5.xml"
        intermittent_second = root / "iter-6.xml"
        write_xunit(intermittent_first, [("SuiteC", "intermittent", "passed")])
        write_xunit(intermittent_second, [("SuiteC", "intermittent", "skipped")])
        result = run_report([intermittent_first, intermittent_second])
        assert result.returncode == 1, result.stdout
        assert "SuiteC.intermittent: skipped 1/2 iterations" in result.stdout, result.stdout

        # An absent case is a failed observation for the iteration rather than
        # disappearing from the denominator.
        seventh = root / "iter-7.xml"
        eighth = root / "iter-8.xml"
        write_xunit(seventh, [("SuiteD", "absent", "passed")])
        write_xunit(eighth, [])
        result = run_report([seventh, eighth])
        assert result.returncode == 1, result.stdout
        assert "SuiteD.absent: failed 1/2 iterations" in result.stdout, result.stdout

        # A single iteration cannot detect flakes: exit 2.
        result = run_report([first])
        assert result.returncode == 2, result.stdout

    print("detect-flaky-tests fixtures passed.")


if __name__ == "__main__":
    main()
