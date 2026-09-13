#!/usr/bin/env python3
"""Open/closed tests for Scripts/generate-doc-navigation.py.

Copies the generator into a synthetic fixture tree (it resolves outputs from
its own location) and asserts `--check` fails on stale outputs, succeeds
after generation, and fails again when an output is tampered with.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/generate-doc-navigation.py"


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    catalog_path = root / "docs/catalog.json"
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((ROOT / "docs/catalog.json").read_text(encoding="utf-8"))
    catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
    return scripts / SCRIPT.name


def run_generator(script: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def test_stale_outputs_are_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        script = make_fixture(Path(directory))
        result = run_generator(script, "--check")
        assert result.returncode == 1, result.stdout + result.stderr
        assert "Generated documentation is stale" in result.stderr, result.stderr


def test_generated_outputs_pass_check() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        assert run_generator(script).returncode == 0
        for relative in (
            "docs/index.html",
            "docs/stable/index.html",
            "docs/next/index.html",
            "docs/NAVIGATION.md",
            "llms.txt",
        ):
            assert (root / relative).exists(), f"generator must emit {relative}"
        result = run_generator(script, "--check")
        assert result.returncode == 0, result.stdout + result.stderr


def test_tampered_output_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        assert run_generator(script).returncode == 0
        landing = root / "docs/index.html"
        landing.write_text(landing.read_text(encoding="utf-8") + "<!-- drift -->", encoding="utf-8")
        result = run_generator(script, "--check")
        assert result.returncode == 1, result.stdout + result.stderr
        assert "docs/index.html" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_stale_outputs_are_rejected,
        test_generated_outputs_pass_check,
        test_tampered_output_is_rejected,
    ]
    for test in tests:
        test()
    print(f"doc navigation generator script tests passed ({len(tests)} tests)")
