#!/usr/bin/env python3
"""Fixture test for Scripts/detect-flaky-tests.py (issue #155 nightly job)."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "detect-flaky-tests.py"


def write_xunit(path: Path, cases: list[tuple[str, str, bool]]) -> None:
    body = ['<?xml version="1.0" encoding="UTF-8"?>', "<testsuites>"]
    for classname, name, passed in cases:
        body.append(f'<testcase classname="{classname}" name="{name}">')
        if not passed:
            body.append("<failure message=\"boom\"/>")
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
        write_xunit(first, [("SuiteA", "testOne", True), ("SuiteA", "testTwo", True)])
        write_xunit(second, [("SuiteA", "testOne", True), ("SuiteA", "testTwo", True)])
        result = run_report([first, second])
        assert result.returncode == 0, result.stdout
        assert "All tests passed every iteration." in result.stdout, result.stdout

        # One flaky (fails 1/2) and one consistently failing (2/2): exit 1, both
        # reported by name with failing iteration counts.
        third = root / "iter-3.xml"
        fourth = root / "iter-4.xml"
        write_xunit(third, [("SuiteA", "flakyOne", False), ("SuiteB", "alwaysRed", False)])
        write_xunit(fourth, [("SuiteA", "flakyOne", True), ("SuiteB", "alwaysRed", False)])
        result = run_report([third, fourth])
        assert result.returncode == 1, result.stdout
        assert "SuiteA.flakyOne: failed 1/2 iterations" in result.stdout, result.stdout
        assert "SuiteB.alwaysRed: failed 2/2 iterations" in result.stdout, result.stdout

        # Skipped cases do not count as passes, and an absent case is a failed
        # observation for the iteration rather than disappearing from the denominator.
        fifth = root / "iter-5.xml"
        sixth = root / "iter-6.xml"
        write_xunit(fifth, [("SuiteC", "intermittent", True)])
        sixth.write_text('<testsuites><testcase classname="SuiteC" name="intermittent"><skipped/></testcase></testsuites>', encoding="utf-8")
        result = run_report([fifth, sixth])
        assert result.returncode == 1, result.stdout
        assert "SuiteC.intermittent: failed 1/2 iterations" in result.stdout, result.stdout

        seventh = root / "iter-7.xml"
        eighth = root / "iter-8.xml"
        write_xunit(seventh, [("SuiteD", "absent", True)])
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
