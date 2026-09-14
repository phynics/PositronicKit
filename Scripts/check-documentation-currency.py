#!/usr/bin/env python3
"""Check current user documentation for retired API names and required boundaries."""

from __future__ import annotations

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
CURRENT_DOCS = [
    ROOT / "README.md",
    ROOT / "docs/Setup.md",
    ROOT / "docs/Usage.md",
    ROOT / "docs/Architecture.md",
    ROOT / "docs/PKPromptComposition.md",
    ROOT / "docs/SidecarDirectives.md",
    ROOT / "docs/Development.md",
    ROOT / "docs/Testing.md",
    ROOT / "docs/Releasing.md",
    ROOT / "docs/ProviderCapabilityMatrix.md",
    ROOT / "Sources/PositronicKit/PositronicKit.docc/PositronicKit.md",
    ROOT / "Sources/PositronicKit/PositronicKit.docc/ArchitectureOverview.md",
    ROOT / "Sources/PositronicKit/PositronicKit.docc/PersistenceLayer.md",
]

RETIRED_TEXT = {
    "thread.send(": "use ThreadHandle.startTurn or ThreadHandle.startDirectTurn",
    "Thread-scoped context": "use AgentContextSource or TurnContextSource",
    "Context Gathering": "use the captured Agent and Turn context",
    "`MessageStoreProtocol`": "use `ThreadMessageStoreProtocol`",
    "RuntimeToolPolicyConfiguration": "use RuntimeToolPolicy",
    "api/4.0-public-api-": "use the current public API baselines",
    "api/5.0-public-api-": "use the 5.1 public API baselines",
}

REQUIRED_TEXT = {
    ROOT / "docs/Setup.md": ("PersistenceConfiguration.fullyPersistent", "workspaceBindingRepository"),
    ROOT / "docs/Usage.md": ("startDirectTurn", "ThreadHandle.startTurn"),
    ROOT / "docs/Architecture.md": ("ThreadRuntimeRepository", "call_tool"),
    ROOT / "Sources/PositronicKit/PositronicKit.docc/ArchitectureOverview.md": (
        "ThreadRuntimeRepository",
        "PromptJournal",
    ),
    ROOT / "Sources/PositronicKit/PositronicKit.docc/PersistenceLayer.md": (
        "ThreadMessageStoreProtocol",
        "fullyPersistent(...)",
    ),
}


def main() -> int:
    errors: list[str] = []
    for path in CURRENT_DOCS:
        text = path.read_text(encoding="utf-8")
        for retired, replacement in RETIRED_TEXT.items():
            if retired in text:
                errors.append(f"{path.relative_to(ROOT)} contains retired text {retired!r}; {replacement}")
    for path, required in REQUIRED_TEXT.items():
        text = path.read_text(encoding="utf-8")
        for phrase in required:
            if phrase not in text:
                errors.append(f"{path.relative_to(ROOT)} must mention {phrase!r}")
    if errors:
        print("documentation currency check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"documentation currency passed ({len(CURRENT_DOCS)} current documents)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
