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


def baseline(platform_name: str) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "release": "6.0",
        "platform": platform_name,
        "modules": ["PKContracts"],
        "symbols": [{"precise": "example", "module": "PKContracts"}],
        "relationships": [],
    }


def test_promotes_both_graphs_and_is_idempotent() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        api = root / "api"
        api.mkdir()
        for platform_name in MODULE.PLATFORMS:
            (api / f"6.0-public-api-{platform_name}.json").write_text(
                json.dumps(baseline(platform_name)),
                encoding="utf-8",
            )

        destinations = MODULE.promote_baselines(root, "6.0.0", "6.1.0")
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

        assert MODULE.promote_baselines(root, "6.0.0", "6.1.0") == expected


def test_conflicting_target_fails_without_writing_other_platform() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        api = root / "api"
        api.mkdir()
        for platform_name in MODULE.PLATFORMS:
            (api / f"6.0-public-api-{platform_name}.json").write_text(
                json.dumps(baseline(platform_name)),
                encoding="utf-8",
            )
        conflict = baseline("macos")
        conflict["symbols"] = []
        (api / "6.1-public-api-macos.json").write_text(
            json.dumps(conflict),
            encoding="utf-8",
        )

        try:
            MODULE.promote_baselines(root, "6.0.0", "6.1.0")
        except ValueError as exc:
            assert "refusing to overwrite a different baseline" in str(exc)
        else:
            raise AssertionError("conflicting target baseline was overwritten")

        assert not (api / "6.1-public-api-linux.json").exists()


def test_rejects_mismatched_source_release() -> None:
    try:
        MODULE.promoted_document(
            baseline("linux"),
            from_release="5.1",
            to_release="6.1",
            platform_name="linux",
        )
    except ValueError as exc:
        assert "expected '5.1'" in str(exc)
    else:
        raise AssertionError("mismatched source release was accepted")


if __name__ == "__main__":
    tests = [
        test_promotes_both_graphs_and_is_idempotent,
        test_conflicting_target_fails_without_writing_other_platform,
        test_rejects_mismatched_source_release,
    ]
    for test in tests:
        test()
    print(f"public API baseline promotion tests passed ({len(tests)} tests)")
