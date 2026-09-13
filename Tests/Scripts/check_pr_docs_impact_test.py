#!/usr/bin/env python3
"""Open/closed tests for Scripts/check-pr-docs-impact.py.

The script is driven by the GitHub event file in `GITHUB_EVENT_PATH`, so
each case stages a synthetic event payload: missing file (outside Actions),
a non-PR event, a PR body without the declaration, and a PR body with it.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-pr-docs-impact.py"


def run_gate(event: dict | None) -> subprocess.CompletedProcess[str]:
    environment = {k: v for k, v in os.environ.items() if k != "GITHUB_EVENT_PATH"}
    if event is not None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False, encoding="utf-8"
        ) as handle:
            json.dump(event, handle)
            environment["GITHUB_EVENT_PATH"] = handle.name
    try:
        return subprocess.run(
            ["python3", str(SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )
    finally:
        path = environment.get("GITHUB_EVENT_PATH")
        if path:
            Path(path).unlink(missing_ok=True)


def test_skipped_outside_actions() -> None:
    result = run_gate(None)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "skipped outside GitHub Actions" in result.stdout, result.stdout


def test_skipped_for_non_pr_event() -> None:
    result = run_gate({"push": {"ref": "refs/heads/main"}})
    assert result.returncode == 0, result.stdout + result.stderr
    assert "skipped for non-PR event" in result.stdout, result.stdout


def test_missing_declaration_is_rejected() -> None:
    result = run_gate({"pull_request": {"body": "## Summary\n\nNo docs section.\n"}})
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Docs / ADR impact" in result.stdout, result.stdout


def test_empty_declaration_is_rejected() -> None:
    body = "## Docs / ADR impact\n\n<!-- nothing -->\n\n## Other\n"
    result = run_gate({"pull_request": {"body": body}})
    assert result.returncode == 1, result.stdout + result.stderr


def test_declaration_passes() -> None:
    body = "## Docs / ADR impact\n\nAdds docs/Testing.md.\n"
    result = run_gate({"pull_request": {"body": body}})
    assert result.returncode == 0, result.stdout + result.stderr
    assert "declaration passed" in result.stdout, result.stdout


if __name__ == "__main__":
    tests = [
        test_skipped_outside_actions,
        test_skipped_for_non_pr_event,
        test_missing_declaration_is_rejected,
        test_empty_declaration_is_rejected,
        test_declaration_passes,
    ]
    for test in tests:
        test()
    print(f"pr docs impact script tests passed ({len(tests)} tests)")
