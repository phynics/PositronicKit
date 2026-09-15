#!/usr/bin/env python3
"""Fail-closed tests for Scripts/check-documentation-currency.py.

The script resolves its repository from its own location, so each case copies
it into a synthetic fixture tree containing the current-document set. The
clean fixture tree must pass, and the fail-closed directions are asserted: a
retired phrase or a missing required phrase must exit non-zero naming the
violation. The full-checkout positive direction is additionally covered by
`make verify-documentation`.

Note: CURRENT_DOCS and REQUIRED_SNIPPETS below are hand-mirrored from
Scripts/check-documentation-currency.py, which is the source of truth. If the
script gains a document or a required phrase, the clean fixture fails here
with a FileNotFoundError (or a "must mention" failure) until this mirror is
updated alongside it.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-documentation-currency.py"

CURRENT_DOCS = (
    "README.md",
    "docs/Setup.md",
    "docs/Usage.md",
    "docs/Architecture.md",
    "docs/PKPromptComposition.md",
    "docs/SidecarDirectives.md",
    "docs/Development.md",
    "docs/Testing.md",
    "docs/Releasing.md",
    "docs/ProviderCapabilityMatrix.md",
    "Sources/PositronicKit/PositronicKit.docc/PositronicKit.md",
    "Sources/PositronicKit/PositronicKit.docc/ArchitectureOverview.md",
    "Sources/PositronicKit/PositronicKit.docc/PersistenceLayer.md",
)

REQUIRED_SNIPPETS = {
    "docs/Setup.md": "PersistenceConfiguration.fullyPersistent workspaceBindingRepository",
    "docs/Usage.md": "startDirectTurn TimelineHandle.startTurn",
    "docs/Architecture.md": "TimelineRuntimeRepository call_tool",
    "Sources/PositronicKit/PositronicKit.docc/ArchitectureOverview.md": (
        "TimelineRuntimeRepository PromptJournal"
    ),
    "Sources/PositronicKit/PositronicKit.docc/PersistenceLayer.md": (
        "TimelineRuntimeRepository TimelineMessageStoreProtocol fullyPersistent(...)"
    ),
}


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    for relative in CURRENT_DOCS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(REQUIRED_SNIPPETS.get(relative, "# Fixture\n"), encoding="utf-8")
    return scripts / SCRIPT.name


def run_check(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        script = make_fixture(Path(directory))
        result = run_check(script)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "documentation currency passed" in result.stdout, result.stdout


def test_retired_phrase_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        target = root / "docs/Setup.md"
        target.write_text(
            "PersistenceConfiguration.fullyPersistent workspaceBindingRepository "
            "RuntimeToolPolicyConfiguration\n",
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "contains retired text" in result.stderr, result.stderr


def test_missing_required_phrase_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        target = root / "docs/Setup.md"
        target.write_text("PersistenceConfiguration.fullyPersistent\n", encoding="utf-8")
        result = run_check(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "must mention" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_clean_tree_passes,
        test_retired_phrase_is_rejected,
        test_missing_required_phrase_is_rejected,
    ]
    for test in tests:
        test()
    print(f"documentation currency script tests passed ({len(tests)} tests)")
