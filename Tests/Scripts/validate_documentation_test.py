#!/usr/bin/env python3
"""Fail-closed tests for Scripts/validate-documentation.py.

The validator resolves its repository from its own location, so each case
copies it into a synthetic fixture tree. Only the fail-closed directions are
asserted here: a violating fixture must exit non-zero naming the violation.
The positive direction is covered by `make verify-documentation` on a full
checkout.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/validate-documentation.py"


def make_fixture(root: Path) -> tuple[Path, Path]:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    catalog_source = ROOT / "docs/catalog.json"
    catalog_path = root / "docs/catalog.json"
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(catalog_source, catalog_path)
    shutil.copyfile(ROOT / "Package.swift", root / "Package.swift")
    consumer = root / "Tests/PublicProductConsumer/main.swift"
    consumer.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "Tests/PublicProductConsumer/main.swift", consumer)
    (root / "README.md").write_text("# Fixture\n", encoding="utf-8")
    (root / "AGENTS.md").write_text("docs/catalog.json\n", encoding="utf-8")
    template = root / ".github/pull_request_template.md"
    template.parent.mkdir(parents=True, exist_ok=True)
    template.write_text("## Docs / ADR impact\n", encoding="utf-8")
    return scripts / SCRIPT.name, catalog_path


def run_validator(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_missing_guide_path_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script, catalog_path = make_fixture(root)
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog["guides"].append(
            {"title": "Missing", "path": "docs/NoSuchGuide.md", "summary": "violation fixture"}
        )
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
        result = run_validator(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "catalog guide path does not exist: docs/NoSuchGuide.md" in result.stderr, result.stderr


def test_missing_product_docs_are_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script, catalog_path = make_fixture(root)
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog["products"].append(
            {
                "name": "PKMissing",
                "kind": "executable",
                "module": "PKMissing",
                "docs": "docs/NoSuchProduct.md",
                "docc": False,
                "consumer": "PKMissing",
            }
        )
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
        result = run_validator(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "PKMissing references missing documentation: docs/NoSuchProduct.md" in result.stderr, (
            result.stderr
        )


if __name__ == "__main__":
    tests = [
        test_missing_guide_path_is_rejected,
        test_missing_product_docs_are_rejected,
    ]
    for test in tests:
        test()
    print(f"documentation validator script tests passed ({len(tests)} tests)")
