#!/usr/bin/env python3
"""Fail-closed tests for Scripts/check-workspace-tool-dispatch.py.

Copies the gate script into a synthetic fixture tree (seeding the positive
case with the real router sources) and asserts violations in either source
file exit non-zero with the documented diagnostic.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-workspace-tool-dispatch.py"
ROUTER = "Sources/PositronicKit/Services/Tools/ToolRouter.swift"
DISPATCHER = "Sources/PositronicKit/Services/Tools/WorkspaceToolDispatcher.swift"


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    router = root / ROUTER
    router.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / ROUTER, router)
    dispatcher = root / DISPATCHER
    shutil.copyfile(ROOT / DISPATCHER, dispatcher)
    return scripts / SCRIPT.name


def run_gate(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_tree_passes() -> None:
    with tempfile.TemporaryDirectory() as directory:
        script = make_fixture(Path(directory))
        result = run_gate(script)
        assert result.returncode == 0, result.stdout + result.stderr


def test_router_regression_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        router = root / ROUTER
        router.write_text(
            router.read_text(encoding="utf-8") + "\nfunc probe() { resolveWorkspace(id) }\n",
            encoding="utf-8",
        )
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "ToolRouter regained live Workspace lookup" in result.stderr, result.stderr


def test_dispatcher_regression_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        dispatcher = root / DISPATCHER
        source = dispatcher.read_text(encoding="utf-8")
        stripped = source.replace("func prepare(", "func removedPrepare(")
        assert stripped != source, "fixture must actually drop the prepare interface"
        dispatcher.write_text(stripped, encoding="utf-8")
        result = run_gate(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "WorkspaceToolDispatcher lost captured-catalog preparation interface" in result.stderr, result.stderr


if __name__ == "__main__":
    tests = [
        test_clean_tree_passes,
        test_router_regression_is_rejected,
        test_dispatcher_regression_is_rejected,
    ]
    for test in tests:
        test()
    print(f"workspace tool dispatch script tests passed ({len(tests)} tests)")
