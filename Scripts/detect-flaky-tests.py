#!/usr/bin/env python3
"""Report flaky tests from repeated full-suite runs (issue #155 nightly job).

Each iteration of the nightly job runs the full suite once and records xUnit XML
via ``swift test --xunit-output iteration-<n>.xml``. This script aggregates those
files and reports every test that did not pass every run, by name, with the
failing iteration count.

Usage:
    python3 Scripts/detect-flaky-tests.py --report iteration-*.xml [--summary PATH]

Exit status is 0 when every test passed every iteration, 1 when any test failed
at least once (flaky or consistently failing), and 2 on unusable input. The
nightly workflow runs on a schedule only — it reports and never gates PRs.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_xunit(path: Path) -> dict[str, bool]:
    """Map test ID to True when it passed for one iteration's xUnit file.

    Skipped cases are recorded as failures: a skipped run did not pass and
    must not hide an intermittent failure.
    """
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise SystemExit(f"detect-flaky-tests: cannot parse {path}: {error}")
    results: dict[str, bool] = {}
    for case in root.iter("testcase"):
        classname = case.get("classname", "")
        name = case.get("name", "")
        test_id = f"{classname}.{name}" if classname else name
        failed = (case.find("failure") is not None or case.find("error") is not None
                  or case.find("skipped") is not None)
        results[test_id] = not failed
    return results


def classify(per_test: dict[str, list[bool]]) -> tuple[list[tuple[str, int, int]], list[tuple[str, int]]]:
    """Split into (flaky, failing) lists.

    Flaky entries are (name, failed_count, ran_count); failing entries are
    (name, ran_count) for tests that never passed.
    """
    flaky: list[tuple[str, int, int]] = []
    failing: list[tuple[str, int]] = []
    for name in sorted(per_test):
        outcomes = per_test[name]
        failures = outcomes.count(False)
        if failures == len(outcomes):
            failing.append((name, len(outcomes)))
        elif failures > 0:
            flaky.append((name, failures, len(outcomes)))
    return flaky, failing


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

    per_test: dict[str, list[bool]] = {}
    for iteration_index, path in enumerate(paths):
        iteration = parse_xunit(path)
        new_names = set(iteration) - set(per_test)
        for name in new_names:
            per_test[name] = [False] * iteration_index
        for name in per_test:
            per_test[name].append(iteration.get(name, False))

    flaky, failing = classify(per_test)
    total = len(per_test)
    lines = [
        "# Flake-detection report",
        "",
        f"Iterations: {len(paths)}",
        f"Tests observed: {total}",
        f"Flaky tests: {len(flaky)}",
        f"Consistently failing tests: {len(failing)}",
        "",
    ]
    if flaky:
        lines.append("## Flaky (failed at least once, passed at least once)")
        lines.extend(f"- {name}: failed {count}/{ran} iterations" for name, count, ran in flaky)
        lines.append("")
    if failing:
        lines.append("## Consistently failing (never passed)")
        lines.extend(f"- {name}: failed {ran}/{ran} iterations" for name, ran in failing)
        lines.append("")
    if not flaky and not failing:
        lines.append("All tests passed every iteration.")
        lines.append("")
    report = "\n".join(lines)
    print(report, end="")
    if args.summary:
        Path(args.summary).write_text(report, encoding="utf-8")

    return 0 if not flaky and not failing else 1


if __name__ == "__main__":
    raise SystemExit(main())
