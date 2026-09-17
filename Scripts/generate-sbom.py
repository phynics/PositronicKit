#!/usr/bin/env python3
"""Generate and validate the release Software Bill of Materials (SBOM).

SwiftPM 6.4 (SE-0509) can emit CycloneDX and SPDX SBOMs for the package graph.
CycloneDX is the release format because it is what downstream dependency
scanners read. This script drives the accurate build-based path
(`swift build --build-system swiftbuild`, which applies build-time conditionals)
and then refuses to publish a document that does not list the package's
products with their dependency edges.

The package SBOM records one component per product and a `dependencies` edge
from each product to its resolved packages, so a release proves that, for
example, `PKOpenAIProvider` pulls in `MacPaw/OpenAI` while `PKContracts` does
not. `validate_sbom` pins that attribution; the fixture tests in
`Tests/Scripts/generate_sbom_test.py` exercise it without a Swift toolchain.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = ROOT / ".build" / "sboms"
DEFAULT_FORMAT = "cyclonedx"
FORMAT_SUFFIX = {"cyclonedx": "cyclonedx.json", "spdx": "spdx.json"}

# Product -> dependency marker -> relation. `depends` requires the product's
# SBOM dependency edge to reach a component built from the marker; `excludes`
# requires it not to. The pair records the audited attribution the release has
# to preserve, and fails closed if SwiftPM stops attributing a package per
# product.
ATTRIBUTION_CHECKS = (
    ("PKOpenAIProvider", "MacPaw/openai", "depends"),
    ("PKContracts", "MacPaw/openai", "excludes"),
)


def required_products_from_catalog(catalog_path: Path = ROOT / "docs" / "catalog.json") -> tuple[str, ...]:
    """Return the public library products the SBOM must list as components."""
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    products = []
    for product in catalog.get("products", []):
        if product.get("kind") != "library" or product.get("testOnly"):
            continue
        products.append(product["name"])
    return tuple(products)


def _dependency_matches(marker: str, reference: str, components: dict[str, dict]) -> bool:
    marker = marker.lower()
    if marker in reference.lower():
        return True
    component = components.get(reference)
    if component is None:
        return False
    haystack = " ".join(
        str(component.get(field, "")) for field in ("name", "purl", "bom-ref")
    ).lower()
    return marker in haystack


def validate_sbom(
    document: object,
    required_products: tuple[str, ...] = (),
    attribution: tuple[tuple[str, str, str], ...] = ATTRIBUTION_CHECKS,
) -> list[str]:
    """Return every reason `document` is not a publishable release SBOM."""
    if not isinstance(document, dict):
        return ["SBOM must be a JSON object"]

    errors: list[str] = []
    if document.get("bomFormat") != "CycloneDX":
        errors.append("SBOM must be CycloneDX (bomFormat: 'CycloneDX')")

    components_list = document.get("components")
    if not isinstance(components_list, list) or not components_list:
        errors.append("SBOM must list components")
        return errors

    by_ref: dict[str, dict] = {}
    by_name: dict[str, dict] = {}
    for component in components_list:
        if not isinstance(component, dict):
            continue
        reference = component.get("bom-ref")
        if isinstance(reference, str):
            by_ref[reference] = component
        name = component.get("name")
        if isinstance(name, str) and name not in by_name:
            by_name[name] = component

    dependencies: dict[str, list[str]] = {}
    for entry in document.get("dependencies") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("ref"), str):
            continue
        depends_on = entry.get("dependsOn")
        dependencies[entry["ref"]] = depends_on if isinstance(depends_on, list) else []

    for product in required_products:
        component = by_name.get(product)
        if component is None:
            errors.append(f"SBOM is missing product component {product!r}")
        elif not isinstance(component.get("bom-ref"), str):
            errors.append(f"product component {product!r} has no bom-ref")

    for product, marker, relation in attribution:
        component = by_name.get(product)
        if component is None:
            continue
        references = dependencies.get(component.get("bom-ref", ""), [])
        found = any(_dependency_matches(marker, reference, by_ref) for reference in references)
        if relation == "depends" and not found:
            errors.append(f"{product} must depend on {marker}")
        elif relation == "excludes" and found:
            errors.append(f"{product} must not depend on {marker}")

    return errors


def swift_command(format: str, output_dir: Path, build: bool) -> list[str]:
    """Return the SwiftPM 6.4 command that writes an SBOM into `output_dir`."""
    if build:
        # The build-based path applies build-time conditionals, so it is the
        # more accurate document; the guide recommends it for releases.
        return [
            "swift", "build", "--build-system", "swiftbuild",
            "--sbom-spec", format, "--sbom-output-dir", str(output_dir),
        ]
    return [
        "swift", "package", "generate-sbom",
        "--sbom-spec", format, "--sbom-output-dir", str(output_dir),
    ]


def artifact_name(format: str, version: str | None) -> str:
    suffix = FORMAT_SUFFIX[format]
    return f"PositronicKit-{version}.{suffix}" if version else f"PositronicKit.{suffix}"


def generate(format: str, output_dir: Path, version: str | None, build: bool) -> Path:
    """Run SwiftPM, validate the generated SBOM, and return the stable artifact path."""
    output_dir.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=".raw-", dir=output_dir))
    try:
        try:
            result = subprocess.run(swift_command(format, scratch, build), cwd=ROOT, check=False)
        except FileNotFoundError:
            raise SystemExit(
                "generate-sbom: 'swift' was not found on PATH; run this through the pinned "
                "Swift 6.4 environment (see docs/Development.md)"
            ) from None
        if result.returncode:
            raise SystemExit(f"generate-sbom: SwiftPM exited {result.returncode}")

        generated = sorted(scratch.glob("*.json"))
        if len(generated) != 1:
            raise SystemExit(
                f"generate-sbom: expected exactly one JSON SBOM in {scratch}, found {len(generated)}"
            )

        document = json.loads(generated[0].read_text(encoding="utf-8"))
        errors = validate_sbom(document, required_products_from_catalog())
        if errors:
            raise SystemExit("generate-sbom: " + "; ".join(errors))

        destination = output_dir / artifact_name(format, version)
        shutil.copyfile(generated[0], destination)
        return destination
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--format", choices=sorted(FORMAT_SUFFIX), default=DEFAULT_FORMAT,
        help="SBOM specification to generate (default: %(default)s)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
        help="Directory for the stable SBOM artifact (default: %(default)s)",
    )
    parser.add_argument(
        "--version", default=None,
        help="Release version used in the artifact name, for example 5.1.0",
    )
    parser.add_argument(
        "--check", type=Path, default=None, metavar="PATH",
        help="Validate an existing SBOM instead of generating one",
    )
    parser.add_argument(
        "--no-build", action="store_true",
        help="Use `swift package generate-sbom` (package graph only, less accurate)",
    )
    arguments = parser.parse_args()

    if arguments.check is not None:
        document = json.loads(arguments.check.read_text(encoding="utf-8"))
        errors = validate_sbom(document, required_products_from_catalog())
        if errors:
            for error in errors:
                print(f"generate-sbom: {error}", file=sys.stderr)
            return 1
        print(f"generate-sbom: {arguments.check} is a valid CycloneDX release SBOM")
        return 0

    destination = generate(arguments.format, arguments.output_dir, arguments.version, not arguments.no_build)
    print(f"generate-sbom: wrote {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
