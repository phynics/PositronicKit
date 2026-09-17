#!/usr/bin/env python3
"""Generate a SwiftPM-compatible fast-test filter from Swift Testing tags.

The repository records taxonomy tags in source, then uses
the stable test-name regex interface to select tagged unit/platform suites.
Module test targets without taxonomy annotations are included wholesale,
except for bounded generative suites (``.tags(.generative)``), which run
explicitly or on the nightly flake-detection job and never on the fast loop.
Selection is per suite, not per file. A runtime file that declares one
`.unit` suite alongside an `.integration` suite contributes only the `.unit`
suite, and helper types that merely have "Test" in their name never reach
the filter.
"""

from __future__ import annotations

import re
import sys
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

FAST_TAGS = (".unit", ".platformSpecific")

# A suite declaration: an optional `@Suite(...)` attribute, then any further
# attributes, comments, and declaration modifiers, then the annotated type.
# `@MainActor` and `final` both appear between `@Suite` and `struct`/`class`
# in this repository, so neither may hide a suite from the filter.
_ATTRIBUTE = r"@\w+(?:\((?:[^()]|\([^()]*\))*\))?"
_MODIFIER = r"(?:public|package|internal|fileprivate|private|final)\b"
_LEADING = r"(?:\s|//[^\n]*\n|" + _ATTRIBUTE + r"|" + _MODIFIER + r")*?"
ANNOTATED_SUITE_RE = re.compile(
    r"@Suite(?P<attributes>\((?:[^()]|\([^()]*\))*\))?"
    + _LEADING
    + r"\b(?:struct|class|actor)\s+(?P<name>\w+)"
)
TOP_LEVEL_SUITE_RE = re.compile(
    r"^(?:(?:public|package|internal|final)\s+)*"
    r"(?:struct|class|actor)\s+(?P<name>\w*Tests)\b",
    re.MULTILINE,
)


def annotated_suites(text: str) -> list[tuple[str, str]]:
    """Return (name, attribute-text) for every `@Suite`-annotated type."""
    return [
        (match.group("name"), match.group("attributes") or "")
        for match in ANNOTATED_SUITE_RE.finditer(text)
    ]


def names_from_runtime(path: Path) -> set[str]:
    """Runtime targets are taxonomy-tagged; take only the fast-tagged suites."""
    text = path.read_text(encoding="utf-8")
    if ".tags(.generative)" in text:
        return set()
    if ".tags(.unit)" not in text and ".tags(.platformSpecific)" not in text:
        return set()
    return {
        name
        for name, attributes in annotated_suites(text)
        if any(f".tags({tag})" in attributes for tag in FAST_TAGS)
    }


def names_from_module(path: Path) -> set[str]:
    """Module targets carry no taxonomy; take every suite they declare."""
    text = path.read_text(encoding="utf-8")
    if ".tags(.generative)" in text:
        return set()
    names = {name for name, _ in annotated_suites(text)}
    names.update(match.group("name") for match in TOP_LEVEL_SUITE_RE.finditer(text))
    return names


def main() -> int:
    names: set[str] = set()
    for target in RUNTIME_TARGETS:
        for path in target.rglob("*.swift"):
            names.update(names_from_runtime(path))
    for target in MODULE_TARGETS:
        for path in target.rglob("*.swift"):
            names.update(names_from_module(path))
    if not names:
        print(
            "generate-test-fast-filter: no fast-tagged suites found; "
            "check the taxonomy tags in Tests/",
            file=sys.stderr,
        )
        return 1
    print("|".join(sorted(names)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
