#!/usr/bin/env python3
"""Test Linux coverage target selection and report normalization."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "linux-coverage-report.py"
SPEC = importlib.util.spec_from_file_location("linux_coverage_report", SCRIPT)
assert SPEC and SPEC.loader
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


def file_entry(filename: str, covered: int, count: int) -> dict:
    return {
        "filename": filename,
        "summary": {
            "lines": {"count": count, "covered": covered, "percent": covered * 100 / count},
            "functions": {"count": count, "covered": covered, "percent": covered * 100 / count},
            "regions": {"count": count, "covered": covered, "percent": covered * 100 / count},
            "instantiations": {"count": count, "covered": covered, "percent": covered * 100 / count},
        },
    }


def assert_equal(actual, expected, label: str) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        raw_path = root / "raw.json"
        output_dir = root / "reports"
        raw_path.write_text(
            json.dumps(
                {
                    "data": [
                        {
                            "files": [
                                file_entry(str(root / "Sources/PositronicKit/Runtime.swift"), 8, 10),
                                file_entry(str(root / "Sources/PKContracts/Contracts.swift"), 3, 5),
                                file_entry(str(root / "Sources/PKPrompt/Prompt.swift"), 2, 4),
                                file_entry(str(root / "Sources/PKUtilities/Utilities.swift"), 6, 8),
                                file_entry(str(root / "Sources/PKObservable/Observable.swift"), 1, 1),
                                file_entry(str(root / "Sources/PKOpenAIProvider/Client.swift"), 99, 100),
                                file_entry(str(root / "Tests/PositronicKitTests/RuntimeTests.swift"), 99, 100),
                                file_entry(str(root / "Sources/PositronicKitExamples/main.swift"), 99, 100),
                            ]
                        }
                    ]
                }
            )
        )

        coverage.write_reports(raw_path, output_dir, root)
        normalized = json.loads((output_dir / "module-coverage.json").read_text())
        modules = {module["name"]: module for module in normalized["modules"]}
        assert_equal(list(modules), list(coverage.MODULES), "module order")
        assert_equal(len(modules["PositronicKit"]["files"]), 1, "runtime file selection")
        assert_equal(len(modules["PKContracts"]["files"]), 1, "contracts file selection")
        assert_equal(len(modules["PKPrompt"]["files"]), 1, "prompt file selection")
        assert_equal(len(modules["PKUtilities"]["files"]), 1, "utilities file selection")
        assert_equal(len(modules["PKObservable"]["files"]), 1, "observable file selection")
        assert_equal(sum(len(module["files"]) for module in modules.values()), 5, "target selection")
        assert_equal(modules["PositronicKit"]["summary"]["lines"]["covered"], 8, "line normalization")
        assert_equal(
            (output_dir / "raw-llvm-cov.json").read_bytes(),
            raw_path.read_bytes(),
            "raw report copy",
        )

        duplicate_path = root / "Sources/PositronicKit/Runtime.swift"
        duplicate_report = root / "duplicate.json"
        duplicate_report.write_text(
            json.dumps(
                {
                    "data": [
                        {
                            "files": [
                                file_entry(str(duplicate_path), 8, 10),
                                file_entry(str(root / "Sources/PKContracts/Contracts.swift"), 3, 5),
                                file_entry(str(root / "Sources/PKPrompt/Prompt.swift"), 2, 4),
                                file_entry(str(root / "Sources/PKUtilities/Utilities.swift"), 6, 8),
                                file_entry(str(root / "Sources/PKObservable/Observable.swift"), 1, 1),
                            ]
                        },
                        {"files": [file_entry(str(duplicate_path), 9, 10)]},
                    ]
                }
            )
        )
        duplicate = coverage.normalize(coverage.load_export(duplicate_report), root)
        runtime = next(module for module in duplicate["modules"] if module["name"] == "PositronicKit")
        assert_equal(len(runtime["files"]), 1, "duplicate file merge")
        assert_equal(runtime["summary"]["lines"]["covered"], 9, "duplicate coverage merge")

        alias = root / "checkout-alias"
        alias.symlink_to(root, target_is_directory=True)
        symlink_report = root / "symlink.json"
        symlink_report.write_text(
            json.dumps(
                {
                    "data": [
                        {
                            "files": [
                                file_entry(
                                    str(alias / "Sources/PositronicKit/Runtime.swift"),
                                    8,
                                    10,
                                ),
                                file_entry(str(root / "Sources/PKContracts/Contracts.swift"), 3, 5),
                                file_entry(str(root / "Sources/PKPrompt/Prompt.swift"), 2, 4),
                                file_entry(str(root / "Sources/PKUtilities/Utilities.swift"), 6, 8),
                                file_entry(str(root / "Sources/PKObservable/Observable.swift"), 1, 1),
                            ]
                        }
                    ]
                }
            )
        )
        normalized_symlink = coverage.normalize(coverage.load_export(symlink_report), root)
        assert_equal(
            normalized_symlink["modules"][0]["files"][0]["path"],
            "Sources/PositronicKit/Runtime.swift",
            "resolved source path",
        )
        for name in (
            "raw-llvm-cov.json",
            "module-coverage.json",
            "module-coverage.md",
            "platform-asymmetry.json",
            "platform-asymmetry.md",
        ):
            if not (output_dir / name).is_file():
                raise AssertionError(f"missing report artifact: {name}")

        malformed = root / "malformed.json"
        malformed.write_text("not json")
        try:
            coverage.load_export(malformed)
        except coverage.CoverageReportError:
            pass
        else:
            raise AssertionError("malformed coverage output was accepted")

        missing_modules = root / "missing-modules.json"
        missing_modules.write_text(
            json.dumps(
                {
                    "data": [
                        {
                            "files": [
                                file_entry(str(root / "Sources/PKOpenAIProvider/Client.swift"), 1, 1)
                            ]
                        }
                    ]
                }
            )
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--raw-report",
                str(missing_modules),
                "--output-dir",
                str(root / "missing-reports"),
                "--package-root",
                str(root),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert_equal(result.returncode, 1, "non-matching export exit status")
        if "no source files for configured modules" not in result.stderr:
            raise AssertionError("missing module diagnostic was not reported")

    print("ok: Linux coverage report target selection, normalization, missing data, and malformed output")


if __name__ == "__main__":
    main()
