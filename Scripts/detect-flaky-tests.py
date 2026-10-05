#!/usr/bin/env python3
"""Report flaky tests from repeated full-suite runs (issue #155 nightly job).

Each iteration of the nightly job runs the full suite once and records xUnit XML
via ``swift test --xunit-output iteration-<n>.xml``. This script aggregates those
files and reports every test that did not pass every run, by name, with the
failing iteration count.

A test skipped on *every* iteration is a deterministic platform gate (for example
``.disabled(if: !networkFrameworkAvailable)``), not a failure: it is reported
under "Skipped on this platform" and does not, by itself, fail the run. A test
skipped on only *some* iterations — or absent from one — is still treated as not
passing, so an intermittent skip cannot hide a real failure.

Usage:
    python3 Scripts/detect-flaky-tests.py --report iteration-*.xml [--summary PATH]

Exit status is 0 when every test passed or was skipped on every iteration, 1 when
any test failed or was skipped intermittently, and 2 on unusable input. The
nightly workflow runs on a schedule only — it reports and never gates PRs.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PASSED = "passed"
FAILED = "failed"
SKIPPED = "skipped"


def parse_xunit(path: Path) -> dict[str, str]:
    """Map test ID to one of ``PASSED``/``FAILED``/``SKIPPED`` for one iteration.

    A test that crashed the suite and never reported a case is absent from the
    file; the caller records that as a failed observation for the iteration.
    """
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise SystemExit(f"detect-flaky-tests: cannot parse {path}: {error}")
    results: dict[str, str] = {}
    for case in root.iter("testcase"):
        classname = case.get("classname", "")
        name = case.get("name", "")
        test_id = f"{classname}.{name}" if classname else name
        if case.find("failure") is not None or case.find("error") is not None:
            results[test_id] = FAILED
        elif case.find("skipped") is not None:
            results[test_id] = SKIPPED
        else:
            results[test_id] = PASSED
    return results


def classify(per_test: dict[str, list[str]]) -> tuple[
    list[tuple[str, int, int]],
    list[tuple[str, int, int]],
    list[tuple[str, int]],
    list[tuple[str, int]],
]:
    """Split observations into (flaky_failed, flaky_skipped, failing, skipped).

    Entries are ``(name, count, ran)``. ``flaky_*`` means the test both did not
    pass on some iteration and passed on another; ``failing`` means it never
    passed; ``skipped`` means every observation was a skip.
    """
    flaky_failed: list[tuple[str, int, int]] = []
    flaky_skipped: list[tuple[str, int, int]] = []
    failing: list[tuple[str, int]] = []
    skipped: list[tuple[str, int]] = []
    for name in sorted(per_test):
        outcomes = per_test[name]
        ran = len(outcomes)
        failures = outcomes.count(FAILED)
        skips = outcomes.count(SKIPPED)
        passes = outcomes.count(PASSED)
        if failures:
            if passes == 0 and skips == 0:
                failing.append((name, ran))
            else:
                flaky_failed.append((name, failures, ran))
        elif skips:
            if passes == 0:
                skipped.append((name, ran))
            else:
                flaky_skipped.append((name, skips, ran))
    return flaky_failed, flaky_skipped, failing, skipped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Report flaky tests from xUnit iterations.")
    parser.add_argument("--report", nargs="+", required=True, help="xUnit XML files, one per iteration")
    parser.add_argument("--summary", default=None, help="Optional path to write a Markdown summary")
    args = parser.parse_args(argv)

    paths = [Path(p) for p in args.report]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        print(f"detect-flaky-tests: missing input files: {', '.join(missing)}", file=sys.stderr)
        return 2
    if len(paths) < 2:
        print("detect-flaky-tests: at least two iterations are required to detect flakes", file=sys.stderr)
        return 2

    per_test: dict[str, list[str]] = {}
    for iteration_index, path in enumerate(paths):
        iteration = parse_xunit(path)
        new_names = set(iteration) - set(per_test)
        for name in new_names:
            per_test[name] = [FAILED] * iteration_index
        for name in per_test:
            per_test[name].append(iteration.get(name, FAILED))

    flaky_failed, flaky_skipped, failing, skipped = classify(per_test)
    total = len(per_test)
    flaky_count = len(flaky_failed) + len(flaky_skipped)
    lines = [
        "# Flake-detection report",
        "",
        f"Iterations: {len(paths)}",
        f"Tests observed: {total}",
        f"Flaky tests: {flaky_count}",
        f"Consistently failing tests: {len(failing)}",
        f"Skipped on this platform: {len(skipped)}",
        "",
    ]
    if flaky_count:
        lines.append("## Flaky (did not pass every iteration)")
        lines.extend(f"- {name}: failed {count}/{ran} iterations" for name, count, ran in flaky_failed)
        lines.extend(f"- {name}: skipped {count}/{ran} iterations" for name, count, ran in flaky_skipped)
        lines.append("")
    if failing:
        lines.append("## Consistently failing (never passed)")
        lines.extend(f"- {name}: failed {ran}/{ran} iterations" for name, ran in failing)
        lines.append("")
    if skipped:
        lines.append("## Skipped on this platform (skipped every iteration)")
        lines.extend(f"- {name}: skipped {ran}/{ran} iterations" for name, ran in skipped)
        lines.append("")
    if not flaky_count and not failing and not skipped:
        lines.append("All tests passed every iteration.")
        lines.append("")
    report = "\n".join(lines)
    print(report, end="")
    if args.summary:
        Path(args.summary).write_text(report, encoding="utf-8")

    return 0 if not flaky_count and not failing else 1


if __name__ == "__main__":
    raise SystemExit(main())
