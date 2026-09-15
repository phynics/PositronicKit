#!/usr/bin/env python3
"""Generate a SwiftPM-compatible fast-test filter from Swift Testing tags.

Swift 6.3.3 does not support the Swift Testing ``tag:`` command-line
specifier. The repository still records taxonomy tags in source, then uses
the stable test-name regex interface to select tagged unit/platform suites.
Module test targets without taxonomy annotations are included wholesale,
except for bounded generative suites (``.tags(.generative)``), which run
explicitly or on the nightly flake-detection job and never on the fast loop.
"""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_TARGETS = (
    ROOT / "Tests/PositronicKitTests",
    ROOT / "Tests/PKProviderIntegrationTests",
)
MODULE_TARGETS = (
    ROOT / "Tests/PKContractsTests",
    ROOT / "Tests/PKPromptTests",
    ROOT / "Tests/PKUtilitiesTests",
    ROOT / "Tests/PKObservableTests",
    ROOT / "Tests/PKOpenAIProviderTests",
    ROOT / "Tests/PKOpenRouterProviderTests",
    ROOT / "Tests/PKOllamaProviderTests",
    ROOT / "Tests/PKAnthropicProviderTests",
    ROOT / "Tests/PKFoundationModelsProviderTests",
    ROOT / "Tests/PKTestSupportTests",
)
TYPE_RE = re.compile(r"\b(?:struct|class|actor)\s+(\w+)")


def names_from_runtime(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    if ".tags(.generative)" in text:
        return set()
    if ".tags(.unit)" not in text and ".tags(.platformSpecific)" not in text:
        return set()
    return {
        match.group(1)
        for match in TYPE_RE.finditer(text)
        if "Test" in match.group(1)
    }


def names_from_module(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    if ".tags(.generative)" in text:
        return set()
    return {
        match.group(1)
        for match in TYPE_RE.finditer(text)
        if "Test" in match.group(1)
    }


def main() -> None:
    names: set[str] = set()
    for target in RUNTIME_TARGETS:
        for path in target.rglob("*.swift"):
            names.update(names_from_runtime(path))
    for target in MODULE_TARGETS:
        for path in target.rglob("*.swift"):
            names.update(names_from_module(path))
    print("|".join(sorted(names)))


if __name__ == "__main__":
    main()
