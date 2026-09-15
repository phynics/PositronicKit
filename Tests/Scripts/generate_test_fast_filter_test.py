#!/usr/bin/env python3
"""Fail-closed tests for Scripts/generate-test-fast-filter.py.

The generator resolves its target roots from its own location, so each case
copies it into a synthetic fixture tree. The cases pin the two properties the
fast loop depends on: the filter names exactly the fast-tagged suites, and an
untagged tree fails instead of emitting an empty filter that `swift test`
would expand to the whole suite.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/generate-test-fast-filter.py"

RUNTIME_TARGET = "Tests/PositronicKitTests"
MODULE_TARGET = "Tests/PKUtilitiesTests"


def make_fixture(root: Path) -> Path:
    scripts = root / "Scripts"
    scripts.mkdir(parents=True)
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    (root / RUNTIME_TARGET).mkdir(parents=True)
    (root / MODULE_TARGET).mkdir(parents=True)
    return scripts / SCRIPT.name


def write(root: Path, relative: str, source: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


def run_generator(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )


def selected(result: subprocess.CompletedProcess[str]) -> set[str]:
    return set(result.stdout.strip().split("|")) if result.stdout.strip() else set()


def test_fast_tags_select_only_their_own_suites() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        write(
            root,
            f"{RUNTIME_TARGET}/MixedTagsTests.swift",
            "import Testing\n"
            '@Suite("fast", .tags(.unit))\n'
            "struct FastUnitTests {}\n"
            '@Suite("slow", .tags(.integration))\n'
            "struct SlowIntegrationTests {}\n",
        )
        result = run_generator(script)
        assert result.returncode == 0, result.stderr
        # A file is not the selection unit: the integration suite sharing this
        # file with a unit suite must stay out of the fast loop.
        assert selected(result) == {"FastUnitTests"}, result.stdout


def test_attributes_and_modifiers_do_not_hide_a_suite() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        write(
            root,
            f"{RUNTIME_TARGET}/DecoratedTests.swift",
            "import Testing\n"
            '@Suite("main actor", .tags(.unit))\n'
            "@MainActor\n"
            "struct MainActorTests {}\n"
            "@Suite(.tags(.platformSpecific)) final class FinalClassTests {}\n",
        )
        result = run_generator(script)
        assert result.returncode == 0, result.stderr
        assert selected(result) == {"MainActorTests", "FinalClassTests"}, result.stdout


def test_helper_types_are_not_selected() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        write(
            root,
            f"{RUNTIME_TARGET}/HelpersTests.swift",
            "import Testing\n"
            "@Suite(.tags(.unit))\n"
            "struct RealSuiteTests {\n"
            "    private struct TestError: Error {}\n"
            "    func make() {\n"
            "        struct TestProvider {}\n"
            "    }\n"
            "}\n"
            "private struct HelperTestLogHandler {}\n",
        )
        result = run_generator(script)
        assert result.returncode == 0, result.stderr
        assert selected(result) == {"RealSuiteTests"}, result.stdout


def test_untagged_module_target_is_taken_wholesale() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        write(
            root,
            f"{RUNTIME_TARGET}/AnchorTests.swift",
            "import Testing\n@Suite(.tags(.unit))\nstruct AnchorTests {}\n",
        )
        write(
            root,
            f"{MODULE_TARGET}/RetryTests.swift",
            "import Testing\n"
            "struct RetryTests {\n"
            '    @Suite("nested")\n'
            "    struct NestedConstruction {}\n"
            "    private struct TestDouble {}\n"
            "}\n",
        )
        result = run_generator(script)
        assert result.returncode == 0, result.stderr
        # Module targets carry no taxonomy, so every suite they declare runs —
        # including a nested `@Suite` whose name does not end in "Tests".
        assert selected(result) == {
            "AnchorTests",
            "RetryTests",
            "NestedConstruction",
        }, result.stdout


def test_untagged_runtime_tree_fails_closed() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        script = make_fixture(root)
        write(
            root,
            f"{RUNTIME_TARGET}/UntaggedTests.swift",
            "import Testing\nstruct UntaggedTests {}\n",
        )
        result = run_generator(script)
        assert result.returncode == 1, result.stdout + result.stderr
        assert "no fast-tagged suites found" in result.stderr, result.stderr
        assert result.stdout.strip() == "", result.stdout


if __name__ == "__main__":
    tests = [
        test_fast_tags_select_only_their_own_suites,
        test_attributes_and_modifiers_do_not_hide_a_suite,
        test_helper_types_are_not_selected,
        test_untagged_module_target_is_taken_wholesale,
        test_untagged_runtime_tree_fails_closed,
    ]
    for test in tests:
        test()
    print(f"test fast filter generator tests passed ({len(tests)} tests)")
