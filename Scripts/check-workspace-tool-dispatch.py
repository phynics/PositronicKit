#!/usr/bin/env python3
"""Enforce the deep Workspace tool-dispatch seam."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
ROUTER = ROOT / "Sources/PositronicKit/Services/Tools/ToolRouter.swift"
DISPATCHER = ROOT / "Sources/PositronicKit/Services/Tools/WorkspaceToolDispatcher.swift"

FORBIDDEN_ROUTER_PATTERNS = (
    (r'arguments\["workspaceID"\]', "legacy workspaceID routing dialect"),
    (r"\bresolveWorkspace\s*\(", "live Workspace lookup"),
    (r"\bresolveWorkspaceTool\b", "Workspace selection outside the dispatcher"),
    (r"\bexecuteWorkspaceTool\b", "Workspace execution outside the dispatcher"),
    (r"\boutcomeForWorkspace\b", "Workspace disposition outside the dispatcher"),
    (r"\bfindWorkspaceForTool\b", "live tool-to-Workspace lookup"),
)

REQUIRED_DISPATCHER_PATTERNS = (
    (r"struct\s+WorkspaceToolDispatcher\b", "WorkspaceToolDispatcher module"),
    (r"func\s+prepare\s*\(", "captured-catalog preparation interface"),
    (r"func\s+execute\s*\(", "prepared-dispatch execution interface"),
    (r"func\s+executeDirect\s*\(", "direct Workspace lane interface"),
    (r"requireWorkspaceBinding\s*\(", "pre-side-effect authority revalidation"),
    (r"withWorkspaceExecution\s*\(", "per-Workspace execution lane"),
)


def main() -> int:
    router = ROUTER.read_text()
    dispatcher = DISPATCHER.read_text()
    failures: list[str] = []

    for pattern, description in FORBIDDEN_ROUTER_PATTERNS:
        if re.search(pattern, router):
            failures.append(f"ToolRouter regained {description}")

    for pattern, description in REQUIRED_DISPATCHER_PATTERNS:
        if not re.search(pattern, dispatcher):
            failures.append(f"WorkspaceToolDispatcher lost {description}")

    if not re.search(
        r"func\s+execute\s*\([^)]*availableTools:\s*\[AnyTool\]",
        router,
        re.DOTALL,
    ):
        failures.append("ToolRouter direct execution no longer requires the exposed tool set")

    for failure in failures:
        print(f"runtime architecture: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
