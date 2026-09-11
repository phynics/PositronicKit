#!/usr/bin/env python3
"""Format and failure-mode tests for the provider capability manifest validator."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/validate-provider-capability-matrix.py"
MANIFEST = ROOT / "Tests/PKTestSupport/Fixtures/ProviderCapabilityMatrix.json"
DOCS = ROOT / "docs/ProviderCapabilityMatrix.md"
REGISTRATION = ROOT / "Tests/PositronicKitTests/ProviderCapabilityMatrixTests.swift"


def run_validator(manifest: Path, docs: Path, registration: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--manifest",
            str(manifest),
            "--docs",
            str(docs),
            "--registration",
            str(registration),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def make_fixture(root: Path) -> tuple[Path, Path, Path]:
    manifest = root / "manifest.json"
    docs = root / "matrix.md"
    registration = root / "matrix.swift"
    shutil.copyfile(MANIFEST, manifest)
    shutil.copyfile(DOCS, docs)
    shutil.copyfile(REGISTRATION, registration)
    return manifest, docs, registration


def assert_failed_with(manifest: Path, docs: Path, registration: Path, phrase: str) -> None:
    result = run_validator(manifest, docs, registration)
    assert result.returncode == 1, result.stdout + result.stderr
    assert phrase in result.stderr, result.stderr


def test_valid_manifest_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        fixture = make_fixture(Path(directory))
        result = run_validator(*fixture)
        assert result.returncode == 0, result.stdout + result.stderr


def test_malformed_json_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        manifest.write_text("{not json", encoding="utf-8")
        assert_failed_with(manifest, docs, registration, "could not decode")


def test_duplicate_and_unknown_cases_are_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        document = json.loads(manifest.read_text(encoding="utf-8"))
        duplicate = document["cases"][0].copy()
        duplicate["provider"] = "Unknown Provider"
        duplicate["id"] = document["cases"][0]["id"]
        document["cases"].append(duplicate)
        manifest.write_text(json.dumps(document), encoding="utf-8")
        result = run_validator(manifest, docs, registration)
        assert result.returncode == 1
        assert "unknown provider" in result.stderr
        assert "duplicate provider capability case id" in result.stderr


def test_unknown_capability_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        document = json.loads(manifest.read_text(encoding="utf-8"))
        document["cases"][0]["capability"] = "video-input"
        manifest.write_text(json.dumps(document), encoding="utf-8")
        assert_failed_with(manifest, docs, registration, "unknown capability")


def test_non_object_json_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        manifest.write_text("[]", encoding="utf-8")
        assert_failed_with(manifest, docs, registration, "top level must be an object")


def test_missing_cases_and_registration_are_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        document = json.loads(manifest.read_text(encoding="utf-8"))
        document["cases"] = []
        manifest.write_text(json.dumps(document), encoding="utf-8")
        result = run_validator(manifest, docs, registration)
        assert result.returncode == 1
        assert "non-empty cases array" in result.stderr

        document = json.loads(MANIFEST.read_text(encoding="utf-8"))
        manifest.write_text(json.dumps(document), encoding="utf-8")
        registration.write_text("private let registeredCaseIDs: Set<String> = []", encoding="utf-8")
        result = run_validator(manifest, docs, registration)
        assert result.returncode == 1
        assert "not all registered" in result.stderr


def test_documentation_drift_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        manifest, docs, registration = make_fixture(Path(directory))
        docs.write_text(docs.read_text(encoding="utf-8").replace("Ordered content parts", "Changed value", 1), encoding="utf-8")
        assert_failed_with(manifest, docs, registration, "published capability Markdown table differs")


if __name__ == "__main__":
    tests = [
        test_valid_manifest_passes,
        test_malformed_json_is_rejected,
        test_duplicate_and_unknown_cases_are_rejected,
        test_unknown_capability_is_rejected,
        test_non_object_json_is_rejected,
        test_missing_cases_and_registration_are_rejected,
        test_documentation_drift_is_rejected,
    ]
    for test in tests:
        test()
    print(f"provider capability matrix script tests passed ({len(tests)} tests)")
