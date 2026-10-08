#!/usr/bin/env python3
"""Fail-closed tests for Scripts/check-public-api-baseline-immutability.py.

The script resolves its repository from its own location and compares each
release-named baseline to its `<release>.0` tag, so every case builds a real
temporary Git repository with a copy of the script inside it. The clean tree
must pass, editing a frozen file must fail, editing the Next file must pass,
and a release baseline whose tag does not exist yet must be skipped.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-public-api-baseline-immutability.py"


def baseline(release: str, platform_name: str) -> str:
    return json.dumps(
        {
            "schemaVersion": 2,
            "release": release,
            "platform": platform_name,
            "modules": ["PKContracts"],
            "symbols": [{"precise": "example", "module": "PKContracts"}],
            "relationships": [],
        },
        indent=2,
    ) + "\n"


def git(root: Path, *arguments: str) -> None:
    subprocess.run(
        ("git", *arguments),
        cwd=root,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    script = scripts / SCRIPT.name
    shutil.copyfile(SCRIPT, script)
    api = root / "api"
    api.mkdir()
    (api / "6.0-public-api-linux.json").write_text(baseline("6.0", "linux"), encoding="utf-8")
    (api / "next-public-api-linux.json").write_text(baseline("next", "linux"), encoding="utf-8")

    git(root, "init", "-q")
    git(root, "config", "user.email", "test@example.com")
    git(root, "config", "user.name", "Test")
    git(root, "add", ".")
    git(root, "commit", "-qm", "fixture")
    git(root, "tag", "6.0.0")
    return script


def run_check(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        result = run_check(script)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "match their tags (1 files)" in result.stdout, result.stdout


def test_edited_release_baseline_fails() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "api" / "6.0-public-api-linux.json").write_text(
            baseline("6.0", "linux").replace("example", "edited"),
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "differs from tag 6.0.0" in result.stderr, result.stderr


def test_next_baseline_may_change() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "api" / "next-public-api-linux.json").write_text(
            baseline("next", "linux").replace("example", "edited"),
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 0, result.stdout + result.stderr


def test_untagged_release_baseline_is_skipped() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        (root / "api" / "9.9-public-api-linux.json").write_text(
            baseline("9.9", "linux"),
            encoding="utf-8",
        )
        result = run_check(script)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "tag 9.9.0 is not present" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_clean_tree_passes,
        test_edited_release_baseline_fails,
        test_next_baseline_may_change,
        test_untagged_release_baseline_is_skipped,
    ]
    for test in tests:
        test()
    print(f"public API baseline immutability tests passed ({len(tests)} tests)")
