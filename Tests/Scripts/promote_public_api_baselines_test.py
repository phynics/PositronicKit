#!/usr/bin/env python3
"""Tests for Scripts/promote-public-api-baselines.py."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/promote-public-api-baselines.py"
SPEC = importlib.util.spec_from_file_location("promote_public_api_baselines", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def baseline(platform_name: str, release: str = "next") -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "release": release,
        "platform": platform_name,
        "modules": ["PKContracts"],
        "symbols": [{"precise": "example", "module": "PKContracts"}],
        "relationships": [],
    }


def write_next(api: Path, release: str = "next") -> None:
    for platform_name in MODULE.PLATFORMS:
        (api / f"next-public-api-{platform_name}.json").write_text(
            json.dumps(baseline(platform_name, release)),
            encoding="utf-8",
        )


def test_promotes_next_graphs_to_a_release() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        api = root / "api"
        api.mkdir()
        write_next(api)

        destinations = MODULE.promote_baselines(root, "6.1.0")
        expected = [
            api / "6.1-public-api-linux.json",
            api / "6.1-public-api-macos.json",
        ]
        assert destinations == expected
        for path, platform_name in zip(expected, MODULE.PLATFORMS, strict=True):
            document = json.loads(path.read_text(encoding="utf-8"))
            assert document == {
                **baseline(platform_name),
                "release": "6.1",
            }


def test_existing_release_baseline_is_never_overwritten() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        api = root / "api"
        api.mkdir()
        write_next(api)
        existing = baseline("macos", release="6.1")
        (api / "6.1-public-api-macos.json").write_text(
            json.dumps(existing),
            encoding="utf-8",
        )

        try:
            MODULE.promote_baselines(root, "6.1.0")
        except ValueError as exc:
            assert "refusing to modify the existing release baseline" in str(exc)
        else:
            raise AssertionError("existing release baseline was overwritten")

        assert not (api / "6.1-public-api-linux.json").exists()


def test_rejects_source_that_is_not_next() -> None:
    try:
        MODULE.promoted_document(
            baseline("linux", release="6.0"),
            to_release="6.1",
            platform_name="linux",
        )
    except ValueError as exc:
        assert "expected 'next'" in str(exc)
    else:
        raise AssertionError("non-Next source release was accepted")


if __name__ == "__main__":
    tests = [
        test_promotes_next_graphs_to_a_release,
        test_existing_release_baseline_is_never_overwritten,
        test_rejects_source_that_is_not_next,
    ]
    for test in tests:
        test()
    print(f"public API baseline promotion tests passed ({len(tests)} tests)")
