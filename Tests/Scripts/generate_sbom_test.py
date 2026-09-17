#!/usr/bin/env python3
"""Fail-closed tests for Scripts/generate-sbom.py.

The script's SwiftPM call needs a toolchain, so these cases pin the pure
document validation and the `--check` entry point: a valid CycloneDX release
SBOM passes, while a missing product, a missing product-to-package edge, a
forbidden edge, and a non-CycloneDX document are rejected.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/generate-sbom.py"


def load_module():
    spec = importlib.util.spec_from_file_location("generate_sbom", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


MODULE = load_module()
OPENAI_COMPONENT = {
    "bom-ref": "openai:OpenAI",
    "name": "OpenAI",
    "purl": "pkg:swift/github.com/MacPaw/openai:OpenAI@0.4.8",
    "type": "library",
}


def make_document(
    *,
    products: tuple[str, ...] = ("PKContracts", "PKOpenAIProvider"),
    openai_from: tuple[str, ...] = ("PKOpenAIProvider",),
    bom_format: str = "CycloneDX",
) -> dict:
    components = [
        {"bom-ref": f"workspace:{product}", "name": product, "type": "library"}
        for product in products
    ]
    components.append(dict(OPENAI_COMPONENT))
    dependencies = []
    for product in products:
        depends_on = ["openai:OpenAI"] if product in openai_from else []
        dependencies.append({"ref": f"workspace:{product}", "dependsOn": depends_on})
    return {
        "bomFormat": bom_format,
        "specVersion": "1.7",
        "components": components,
        "dependencies": dependencies,
    }


def test_valid_sbom_passes() -> None:
    errors = MODULE.validate_sbom(make_document(), ("PKContracts", "PKOpenAIProvider"))
    assert errors == [], errors


def test_required_product_missing_is_rejected() -> None:
    errors = MODULE.validate_sbom(make_document(products=("PKContracts",)), ("PKContracts", "PKPrompt"))
    assert any("PKPrompt" in error for error in errors), errors


def test_missing_dependency_edge_is_rejected() -> None:
    errors = MODULE.validate_sbom(make_document(openai_from=()), ("PKContracts", "PKOpenAIProvider"))
    assert any("PKOpenAIProvider must depend on MacPaw/openai" in error for error in errors), errors


def test_forbidden_dependency_edge_is_rejected() -> None:
    errors = MODULE.validate_sbom(
        make_document(openai_from=("PKContracts", "PKOpenAIProvider")), ("PKContracts", "PKOpenAIProvider")
    )
    assert any("PKContracts must not depend on MacPaw/openai" in error for error in errors), errors


def test_non_cyclonedx_is_rejected() -> None:
    errors = MODULE.validate_sbom(make_document(bom_format="SPDX"), ("PKContracts",))
    assert any("CycloneDX" in error for error in errors), errors


def test_build_command_uses_swiftbuild() -> None:
    command = MODULE.swift_command("cyclonedx", Path("/tmp/sbom"), build=True)
    assert command[:2] == ["swift", "build"]
    assert "--build-system" in command and "swiftbuild" in command
    package_command = MODULE.swift_command("cyclonedx", Path("/tmp/sbom"), build=False)
    assert package_command[:3] == ["swift", "package", "generate-sbom"]


def test_check_entry_point_accepts_a_valid_document() -> None:
    products = MODULE.required_products_from_catalog()
    document = make_document(products=products, openai_from=("PKOpenAIProvider",))
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "sbom.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        result = subprocess.run(
            ["python3", str(SCRIPT), "--check", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "valid CycloneDX release SBOM" in result.stdout, result.stdout


if __name__ == "__main__":
    tests = [
        test_valid_sbom_passes,
        test_required_product_missing_is_rejected,
        test_missing_dependency_edge_is_rejected,
        test_forbidden_dependency_edge_is_rejected,
        test_non_cyclonedx_is_rejected,
        test_build_command_uses_swiftbuild,
        test_check_entry_point_accepts_a_valid_document,
    ]
    for test in tests:
        test()
    print(f"generate-sbom script tests passed ({len(tests)} tests)")
