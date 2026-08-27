#!/usr/bin/env python3
"""Validate local release metadata and an annotated tag before it is pushed."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    print(f"release readiness: {message}", file=sys.stderr)
    raise SystemExit(1)


def git(*arguments: str) -> str:
    result = subprocess.run(
        ("git", *arguments), cwd=ROOT, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", sys.argv[1]):
        fail("pass VERSION as a bare semantic version, for example `make verify-release VERSION=5.0.0`")
    version = sys.argv[1]

    catalog = json.loads((ROOT / "docs" / "catalog.json").read_text())
    stable = catalog["stable"]
    if stable.get("version") != version or stable.get("ref") != version:
        fail(f"docs/catalog.json stable.version and stable.ref must both equal {version}")

    changelog = (ROOT / "CHANGELOG.md").read_text()
    release_heading = re.compile(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$", re.MULTILINE)
    if not release_heading.search(changelog):
        fail(f"CHANGELOG.md has no dated [{version}] release section")
    unreleased = re.search(r"^## \[Unreleased\]\s*(.*?)(?=^## \[)", changelog, re.MULTILINE | re.DOTALL)
    if unreleased is None or unreleased.group(1).strip():
        fail("CHANGELOG.md Unreleased must be empty after cutting the release section")

    baseline_release = ".".join(version.split(".")[:2])
    for platform_name in ("linux", "macos"):
        baseline_path = ROOT / "api" / f"{baseline_release}-public-api-{platform_name}.json"
        if not baseline_path.exists():
            fail(f"missing reviewed {platform_name} public API baseline: {baseline_path.relative_to(ROOT)}")
        baseline = json.loads(baseline_path.read_text())
        if baseline.get("release") != baseline_release or baseline.get("platform") != platform_name:
            fail(f"invalid release/platform metadata in {baseline_path.relative_to(ROOT)}")

    tag_ref = f"refs/tags/{version}"
    if git("cat-file", "-t", tag_ref) != "tag":
        fail(f"{version} must be an annotated tag")
    if git("rev-parse", f"{tag_ref}^{{commit}}") != git("rev-parse", "HEAD"):
        fail(f"{version} does not point to HEAD")
    if git("status", "--porcelain"):
        fail("working tree must be clean")

    for command in (
        ("python3", "Scripts/generate-doc-navigation.py", "--check"),
        ("python3", "Scripts/validate-documentation.py"),
    ):
        result = subprocess.run(command, cwd=ROOT, check=False)
        if result.returncode:
            return result.returncode

    print(f"Local release artifacts, stable documentation, and annotated tag {version} agree.")
    print("Confirm the matching GitHub milestone and release text during publication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
