#!/usr/bin/env python3
"""Fail-closed tests for Scripts/validate-release-readiness.py.

The script operates on the real checkout (catalog, changelog, git tags), so the
Git-dependent cases pin the side-effect-free rejection paths: malformed input
and a version the catalog does not declare. The positive direction runs in
`make verify-release` during publication, which requires an annotated tag on a
clean tree.

The public API compatibility gate is pure over file paths, so its cases build
baseline fixtures directly and pin the patch/minor/major rules. The end-to-end
case copies the script into a temporary repository and runs it as the readiness
check, which is the shape a release uses.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/validate-release-readiness.py"
SPEC = importlib.util.spec_from_file_location("validate_release_readiness", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def run_gate(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(SCRIPT), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def symbol(name: str, declaration: str = "let value: Int") -> dict:
    return {
        "precise": f"precise-{name}",
        "module": "PKContracts",
        "kind": "symbol",
        "path": [name],
        "declaration": declaration,
    }


def baseline(release: str, platform_name: str, symbols: list[dict]) -> dict:
    return {
        "schemaVersion": 2,
        "release": release,
        "platform": platform_name,
        "modules": ["PKContracts"],
        "symbols": symbols,
        "relationships": [],
    }


CHANGELOG_MINOR = """# Changelog

## [Unreleased]

## [6.2.0] - 2026-10-01

### Added

- A compatible addition.

## [6.1.0] - 2026-09-30

### Breaking

- An earlier break.
"""

CHANGELOG_MAJOR = """# Changelog

## [Unreleased]

## [7.0.0] - 2026-10-01

### Breaking

- Removed symbols on purpose.

## [6.1.0] - 2026-09-30

### Changed

- A compatible change.
"""


def test_missing_version_is_rejected() -> None:
    result = run_gate()
    assert result.returncode == 1, result.stdout + result.stderr
    assert "bare semantic version" in result.stderr, result.stderr


def test_malformed_version_is_rejected() -> None:
    result = run_gate("5.1")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "bare semantic version" in result.stderr, result.stderr


def test_undeclared_version_is_rejected() -> None:
    result = run_gate("0.0.0")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "stable.version and stable.ref must both equal 0.0.0" in result.stderr, result.stderr


def test_release_kind_uses_the_semver_component() -> None:
    assert MODULE.release_kind("6.1.0") == "minor"
    assert MODULE.release_kind("6.1.1") == "patch"
    assert MODULE.release_kind("6.2.0") == "minor"
    assert MODULE.release_kind("7.0.0") == "major"


def test_minor_rejects_a_removed_symbol() -> None:
    candidate = baseline("6.2", "linux", [symbol("Kept")])
    previous = baseline("6.1", "linux", [symbol("Kept"), symbol("Gone")])
    failures = MODULE.compare_public_surfaces(candidate, previous, "minor")
    assert any("removed public symbol: PKContracts.Gone" in failure for failure in failures), failures


def test_minor_rejects_a_changed_declaration() -> None:
    candidate = baseline("6.2", "linux", [symbol("Kept", declaration="func kept() -> Int")])
    previous = baseline("6.2", "linux", [symbol("Kept", declaration="func kept() -> String")])
    failures = MODULE.compare_public_surfaces(candidate, previous, "minor")
    assert any(
        "changed public symbol declaration: PKContracts.Kept" in failure for failure in failures
    ), failures


def test_minor_accepts_an_added_symbol() -> None:
    candidate = baseline("6.2", "linux", [symbol("Kept"), symbol("New")])
    previous = baseline("6.1", "linux", [symbol("Kept")])
    assert MODULE.compare_public_surfaces(candidate, previous, "minor") == []


def test_patch_rejects_any_symbol_delta() -> None:
    previous = baseline("6.1", "linux", [symbol("Kept")])
    assert MODULE.compare_public_surfaces(
        baseline("6.1", "linux", [symbol("Kept"), symbol("New")]), previous, "patch"
    ), "an added symbol must fail a patch release"
    assert MODULE.compare_public_surfaces(
        baseline("6.1", "linux", [symbol("Kept", declaration="let value: String")]), previous, "patch"
    ), "a changed declaration must fail a patch release"


def test_major_accepts_removals() -> None:
    candidate = baseline("7.0", "linux", [symbol("Kept")])
    previous = baseline("6.1", "linux", [symbol("Kept"), symbol("Gone")])
    assert MODULE.compare_public_surfaces(candidate, previous, "major") == []


def test_major_requires_a_non_empty_breaking_section() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        api = root / "api"
        api.mkdir()
        _write_platform_baselines(root, "7.0", "6.1", [symbol("Kept")], [symbol("Kept"), symbol("Gone")])

        without_breaking = CHANGELOG_MAJOR.replace("### Breaking", "### Changed")
        violations = MODULE.api_semver_violations(
            root, "7.0.0", without_breaking, platforms=("linux",)
        )
        assert any("non-empty `### Breaking` section" in violation for violation in violations), violations

        violations = MODULE.api_semver_violations(
            root, "7.0.0", CHANGELOG_MAJOR, platforms=("linux",)
        )
        assert violations == [], violations


def test_readiness_check_fails_for_a_hypothetical_minor_removal() -> None:
    """The acceptance case: 6.2.0 removes a symbol present in the 6.1.0 baseline."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = _make_script_fixture(root)
        result = subprocess.run(
            ["python3", str(script), "6.2.0"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        assert "removed public symbol: PKContracts.Gone" in result.stderr, result.stderr


def _write_platform_baselines(
    root: Path,
    candidate_release: str,
    previous_release: str,
    candidate_symbols: list[dict],
    previous_symbols: list[dict],
) -> None:
    api = root / "api"
    api.mkdir(exist_ok=True)
    for platform_name in MODULE.API_PLATFORMS:
        (api / f"{candidate_release}-public-api-{platform_name}.json").write_text(
            json.dumps(baseline(candidate_release, platform_name, candidate_symbols)),
            encoding="utf-8",
        )
        (api / f"{previous_release}-public-api-{platform_name}.json").write_text(
            json.dumps(baseline(previous_release, platform_name, previous_symbols)),
            encoding="utf-8",
        )


def _make_script_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    script = scripts / SCRIPT.name
    shutil.copyfile(SCRIPT, script)

    docs = root / "docs"
    docs.mkdir()
    (docs / "catalog.json").write_text(
        json.dumps({"stable": {"version": "6.2.0", "ref": "6.2.0"}}),
        encoding="utf-8",
    )
    (root / "CHANGELOG.md").write_text(CHANGELOG_MINOR, encoding="utf-8")
    _write_platform_baselines(
        root,
        "6.2",
        "6.1",
        [symbol("Kept")],
        [symbol("Kept"), symbol("Gone")],
    )
    return script


if __name__ == "__main__":
    tests = [
        test_missing_version_is_rejected,
        test_malformed_version_is_rejected,
        test_undeclared_version_is_rejected,
        test_release_kind_uses_the_semver_component,
        test_minor_rejects_a_removed_symbol,
        test_minor_rejects_a_changed_declaration,
        test_minor_accepts_an_added_symbol,
        test_patch_rejects_any_symbol_delta,
        test_major_accepts_removals,
        test_major_requires_a_non_empty_breaking_section,
        test_readiness_check_fails_for_a_hypothetical_minor_removal,
    ]
    for test in tests:
        test()
    print(f"release readiness script tests passed ({len(tests)} tests)")
