#!/usr/bin/env python3
"""Ensure every runtime story suite is mapped by the story coverage index.

Story suites live under Tests/PositronicKitTests/Stories/,
Tests/PositronicKitTests/InternalStories/, and
Tests/PKProviderIntegrationTests/Stories/. The hand-maintained
Tests/PositronicKitTests/Stories/StoryCoverageIndex.swift maps each suite to
the user-visible story it covers; this gate fails when a suite file on disk
is missing from the index or when the index names a suite file that no longer
exists, so story coverage cannot silently drift.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "Tests/PositronicKitTests/Stories/StoryCoverageIndex.swift"
STORY_ROOTS = (
    ROOT / "Tests/PositronicKitTests/Stories",
    ROOT / "Tests/PositronicKitTests/InternalStories",
    ROOT / "Tests/PKProviderIntegrationTests/Stories",
)


def main() -> int:
    failures: list[str] = []
    try:
        index = INDEX.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"story coverage: could not read {INDEX.relative_to(ROOT)}: {exc}", file=sys.stderr)
        return 1
    referenced = set(re.findall(r"`([A-Za-z0-9_]+Tests)`", index))

    on_disk: set[str] = set()
    for story_root in STORY_ROOTS:
        if not story_root.is_dir():
            continue
        for path in sorted(story_root.rglob("*.swift")):
            if path == INDEX:
                continue
            on_disk.add(path.stem)

    for suite in sorted(on_disk - referenced):
        failures.append(f"story suite {suite} is not mapped by StoryCoverageIndex.swift")
    for suite in sorted(referenced):
        if not list(ROOT.glob(f"Tests/**/{suite}.swift")):
            failures.append(f"StoryCoverageIndex.swift maps {suite}, which no longer exists")

    for failure in failures:
        print(f"story coverage: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"story coverage index maps {len(on_disk)} story suites")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
