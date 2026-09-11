#!/usr/bin/env python3
"""Normalize SwiftPM's Linux llvm-cov export for the runtime modules."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


MODULES = (
    "PositronicKit",
    "PKContracts",
    "PKPrompt",
    "PKUtilities",
    "PKObservable",
)

EXCLUDED_TARGETS = (
    "provider targets",
    "PKTestSupport",
    "executables",
    "test targets",
)

METRICS = ("lines", "functions", "regions", "instantiations")


class CoverageReportError(ValueError):
    """Raised when an llvm-cov export does not have the expected shape."""


def _require_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CoverageReportError(f"{label} must be an object")
    return value


def _require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise CoverageReportError(f"{label} must be an array")
    return value


def load_export(path: Path) -> dict[str, Any]:
    try:
        report = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise CoverageReportError(f"coverage report does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise CoverageReportError(f"coverage report is not valid JSON: {path}") from error

    root = _require_dict(report, "coverage report")
    data = _require_list(root.get("data"), "coverage report data")
    for index, entry in enumerate(data):
        item = _require_dict(entry, f"coverage report data[{index}]")
        files = item.get("files", [])
        _require_list(files, f"coverage report data[{index}].files")
        for file_index, file_entry in enumerate(files):
            file_data = _require_dict(
                file_entry,
                f"coverage report data[{index}].files[{file_index}]",
            )
            filename = file_data.get("filename")
            if not isinstance(filename, str) or not filename:
                raise CoverageReportError(
                    f"coverage report data[{index}].files[{file_index}].filename must be a string"
                )
    return root


def module_for_path(filename: str, package_root: Path) -> str | None:
    absolute = Path(filename)
    if not absolute.is_absolute():
        absolute = package_root / absolute
    try:
        relative = absolute.resolve().relative_to(package_root.resolve())
    except ValueError:
        return None

    parts = relative.parts
    if len(parts) < 3 or parts[0] != "Sources" or parts[1] not in MODULES:
        return None
    return parts[1]


def _metric(value: Any) -> tuple[int, int]:
    item = _require_dict(value, "coverage metric")
    count = item.get("count")
    covered = item.get("covered")
    if not isinstance(count, int) or not isinstance(covered, int):
        raise CoverageReportError("coverage metrics require integer count and covered values")
    if count < 0 or covered < 0 or covered > count:
        raise CoverageReportError("coverage metrics contain invalid counts")
    return count, covered


def _summary(files: list[dict[str, Any]]) -> dict[str, dict[str, int | float]]:
    totals: dict[str, list[int]] = {metric: [0, 0] for metric in METRICS}
    for file_entry in files:
        summary = _require_dict(file_entry.get("summary", {}), "file summary")
        for metric in METRICS:
            if metric in summary:
                count, covered = _metric(summary[metric])
                totals[metric][0] += count
                totals[metric][1] += covered

    result: dict[str, dict[str, int | float]] = {}
    for metric, (count, covered) in totals.items():
        result[metric] = {
            "count": count,
            "covered": covered,
            "percent": round((covered * 100 / count), 2) if count else 0.0,
        }
    return result


def normalize(report: dict[str, Any], package_root: Path) -> dict[str, Any]:
    data = _require_list(report.get("data"), "coverage report data")
    files_by_module: dict[str, dict[str, dict[str, Any]]] = {module: {} for module in MODULES}

    for entry in data:
        item = _require_dict(entry, "coverage report data entry")
        for file_value in _require_list(item.get("files", []), "coverage report files"):
            file_entry = _require_dict(file_value, "coverage file")
            filename = file_entry.get("filename")
            if not isinstance(filename, str):
                raise CoverageReportError("coverage file filename must be a string")
            module = module_for_path(filename, package_root)
            if module is None:
                continue
            files_by_module[module][filename] = file_entry

    missing_modules = [module for module in MODULES if not files_by_module[module]]
    if missing_modules:
        raise CoverageReportError(
            "coverage report has no source files for configured modules: "
            + ", ".join(missing_modules)
        )

    modules: list[dict[str, Any]] = []
    for module in MODULES:
        files = [files_by_module[module][filename] for filename in sorted(files_by_module[module])]
        modules.append(
            {
                "name": module,
                "files": [
                    {
                        "path": os.path.relpath(file["filename"], package_root),
                        "summary": file.get("summary", {}),
                    }
                    for file in files
                ],
                "summary": _summary(files),
            }
        )

    all_files = [file for module in modules for file in module["files"]]
    return {
        "schemaVersion": 1,
        "platform": "linux",
        "source": "llvm-cov",
        "modules": modules,
        "summary": _summary(all_files),
    }


def asymmetry_report(normalized: dict[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "reportedPlatform": "linux",
        "reportedModules": [module["name"] for module in normalized["modules"]],
        "missingPlatforms": ["macOS"],
        "excludedTargets": list(EXCLUDED_TARGETS),
        "deferredPolicy": [
            "macOS coverage parity",
            "committed baseline policy",
            "per-module floors",
            "changed-line coverage rules",
            "platform-specific enforcement",
        ],
    }


def markdown_summary(normalized: dict[str, Any]) -> str:
    lines = [
        "# Linux coverage summary",
        "",
        "This report includes only the five runtime library modules listed below.",
        "",
        "| Module | Files | Lines | Functions | Regions | Instantiations |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for module in normalized["modules"]:
        summary = module["summary"]
        values = [
            f"{summary[metric]['covered']}/{summary[metric]['count']} ({summary[metric]['percent']:.2f}%)"
            for metric in METRICS
        ]
        lines.append(f"| {module['name']} | {len(module['files'])} | " + " | ".join(values) + " |")
    return "\n".join(lines) + "\n"


def markdown_asymmetry(report: dict[str, Any]) -> str:
    lines = [
        "# Coverage platform asymmetry",
        "",
        "This milestone reports Linux coverage only. macOS coverage and enforcement remain deferred.",
        "",
        "## Included modules",
        "",
    ]
    lines.extend(f"- `{module}`" for module in report["reportedModules"])
    lines.extend(["", "## Excluded targets", ""])
    lines.extend(f"- {target}" for target in report["excludedTargets"])
    lines.extend(["", "## Deferred policy", ""])
    lines.extend(f"- {item}" for item in report["deferredPolicy"])
    return "\n".join(lines) + "\n"


def write_reports(raw_path: Path, output_dir: Path, package_root: Path) -> None:
    report = load_export(raw_path)
    normalized = normalize(report, package_root)
    asymmetry = asymmetry_report(normalized)
    output_dir.mkdir(parents=True, exist_ok=True)

    (output_dir / "raw-llvm-cov.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (output_dir / "module-coverage.json").write_text(
        json.dumps(normalized, indent=2, sort_keys=True) + "\n"
    )
    (output_dir / "module-coverage.md").write_text(markdown_summary(normalized))
    (output_dir / "platform-asymmetry.json").write_text(
        json.dumps(asymmetry, indent=2, sort_keys=True) + "\n"
    )
    (output_dir / "platform-asymmetry.md").write_text(markdown_asymmetry(asymmetry))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-report", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--package-root", type=Path, default=Path.cwd())
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        write_reports(arguments.raw_report, arguments.output_dir, arguments.package_root)
    except CoverageReportError as error:
        print(f"linux-coverage-report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
