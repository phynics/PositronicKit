#!/usr/bin/env python3
"""Generate or verify the reviewed public Swift symbol inventory."""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "docs" / "catalog.json"


def platform_name() -> str:
    system = platform.system()
    if system == "Darwin":
        return "macos"
    if system == "Linux":
        return "linux"
    raise SystemExit(f"unsupported public API baseline platform: {system}")


PLATFORM = platform_name()

# `main` is always checked against the unreleased Next baseline. A release tag
# gets its own immutable `api/<major>.<minor>-public-api-<platform>.json` file
# only when `promote-public-api-baselines.py` copies this one at release time.
BASELINE_RELEASE = "next"


def run_result(*arguments: str) -> tuple[int, str]:
    result = subprocess.run(
        arguments,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return result.returncode, result.stdout.strip()


def run(*arguments: str) -> str:
    status, output = run_result(*arguments)
    if status:
        print(output, end="", file=sys.stderr)
        raise SystemExit(status)
    return output


def symbolgraph_extract_command() -> list[str]:
    """Return the extractor that matches the toolchain on PATH.

    The active Xcode's ``swift-symbolgraph-extract`` cannot read a
    ``.swiftmodule`` produced by a newer toolchain installed on PATH (for
    example the pinned Swift 6.4 release), so prefer the sibling of the
    ``swift`` binary the gate builds with and fall back to xcrun.
    """
    swift_binary = shutil.which("swift")
    if swift_binary:
        candidate = Path(swift_binary).with_name("swift-symbolgraph-extract")
        if candidate.exists():
            return [str(candidate)]
    return ["xcrun", "swift-symbolgraph-extract"]


PRIMARY_BASELINE = ROOT / "api" / f"{BASELINE_RELEASE}-public-api-{PLATFORM}.json"
EXPERIMENTAL_BASELINE = ROOT / "api" / f"{BASELINE_RELEASE}-experimental-api-{PLATFORM}.json"


def public_modules() -> list[str]:
    catalog = json.loads(CATALOG.read_text())
    return sorted({product["module"] for product in catalog["products"] if product["kind"] == "library"})


def declaration(symbol: dict) -> str:
    return "".join(fragment.get("spelling", "") for fragment in symbol.get("declarationFragments", []))


def reported_graph_directory(output: str) -> Path:
    marker = "Files written to "
    paths = [line.removeprefix(marker).strip() for line in output.splitlines() if line.startswith(marker)]
    if not paths:
        raise SystemExit("swift package dump-symbol-graph did not report its output directory")
    path = Path(paths[-1])
    return path if path.is_absolute() else ROOT / path


def read_graphs(graph_dir: Path, modules: list[str]) -> tuple[dict[str, dict], dict[str, dict], set[str]]:
    """Read symbol graphs into precise-keyed symbol and relationship maps."""
    symbols: dict[str, dict] = {}
    relationships: dict[str, dict] = {}
    observed: set[str] = set()
    for graph_path in sorted(graph_dir.rglob("*.symbols.json")):
        graph = json.loads(graph_path.read_text())
        module = graph["module"]["name"]
        if module not in modules:
            continue
        observed.add(module)
        for symbol in graph["symbols"]:
            precise = symbol["identifier"]["precise"]
            entry = {
                "module": module,
                "kind": symbol["kind"]["identifier"],
                "path": symbol["pathComponents"],
                "declaration": declaration(symbol),
            }
            existing = symbols.get(precise)
            if existing is not None and existing != entry:
                raise SystemExit(f"conflicting symbol graph entries for {precise}")
            symbols[precise] = entry
        for relationship in graph.get("relationships", []):
            entry = {
                "module": module,
                **{
                    key: relationship[key]
                    for key in ("kind", "source", "target", "targetFallback", "sourceOrigin")
                    if key in relationship
                },
            }
            relationships[json.dumps(entry, sort_keys=True)] = entry
    return symbols, relationships, observed


def extract_graphs(modules: list[str], bin_path: Path, graph_dir: Path, include_spi: bool) -> None:
    """Extract ``modules`` with swift-symbolgraph-extract into ``graph_dir``.

    SwiftPM's ``dump-symbol-graph --include-spi-symbols`` does not emit SPI
    symbols on Linux, so the experimental pass uses the extractor on every
    platform. Both extractor passes run together so the SPI delta cannot pick up
    an extractor-versus-SwiftPM difference in the stable surface.
    """
    generated_module_maps: Path | None = None
    sdk: str | None = None
    if platform.system() == "Darwin":
        generated_module_maps = bin_path.parent.parent / "Intermediates.noindex" / "GeneratedModuleMaps"
        sdk = run("xcrun", "--show-sdk-path")
    graph_dir.mkdir(parents=True, exist_ok=True)
    for module in modules:
        candidates = list(bin_path.parent.parent.rglob(f"{module}.swiftmodule"))
        if not candidates:
            raise SystemExit(f"missing compiled module: {module}")
        command = [
            *symbolgraph_extract_command(),
            "-module-name", module,
            "-I", str(candidates[0].parent),
            "-output-dir", str(graph_dir),
            "-minimum-access-level", "public",
            "-skip-synthesized-members",
            "-skip-inherited-docs",
        ]
        if generated_module_maps is not None:
            command += ["-I", str(generated_module_maps), "-sdk", sdk]
        if include_spi:
            command.append("-include-spi-symbols")
        run(*command)


def _extract_and_read(
    modules: list[str], bin_path: Path, graph_dir: Path, include_spi: bool
) -> tuple[dict[str, dict], dict[str, dict], set[str]]:
    extract_graphs(modules, bin_path, graph_dir, include_spi)
    symbols, relationships, observed = read_graphs(graph_dir, modules)
    missing = sorted(set(modules) - observed)
    if missing:
        raise SystemExit("missing SPI symbol graphs: " + ", ".join(missing))
    return symbols, relationships, observed


def inventory(include_spi: bool = False) -> dict:
    """Build the reviewed symbol inventory for the catalog's public modules.

    The stable pass records SwiftPM's ``dump-symbol-graph`` output. The SPI pass
    extracts every module twice with the same extractor, so the experimental
    baseline holds only the surfaces SPI adds and never an extractor artifact.
    """
    modules = public_modules()
    bin_path = Path(run("swift", "build", "--show-bin-path").splitlines()[-1])
    if include_spi:
        with tempfile.TemporaryDirectory() as scratch:
            full_symbols, full_relationships, _ = _extract_and_read(
                modules, bin_path, Path(scratch) / "full", include_spi=True
            )
            stable_symbols, stable_relationships, _ = _extract_and_read(
                modules, bin_path, Path(scratch) / "stable", include_spi=False
            )
        symbols = {precise: entry for precise, entry in full_symbols.items() if precise not in stable_symbols}
        relationships = {
            key: entry for key, entry in full_relationships.items() if key not in stable_relationships
        }
        return {
            "schemaVersion": 2,
            "release": BASELINE_RELEASE,
            "platform": PLATFORM,
            "modules": modules,
            "symbols": [dict(precise=precise, **symbols[precise]) for precise in sorted(symbols)],
            "relationships": [relationships[key] for key in sorted(relationships)],
        }

    # SwiftPM places the graphs beside the configuration directory (for
    # example `.build/x86_64-unknown-linux-gnu/symbolgraph`), so resolve from
    # the bin directory rather than the package `.build` root.
    graph_dir = bin_path.parent / "symbolgraph"
    graph_dir.mkdir(parents=True, exist_ok=True)
    for graph in graph_dir.rglob("*.symbols.json"):
        graph.unlink()

    dump_status, dump_output = run_result(
        "swift", "package", "dump-symbol-graph",
        "--minimum-access-level", "public",
        "--skip-synthesized-members",
        "--skip-inherited-docs",
    )
    try:
        graph_dir = reported_graph_directory(dump_output)
    except SystemExit:
        print(dump_output, end="", file=sys.stderr)
        raise SystemExit(
            f"swift package dump-symbol-graph exited {dump_status} without reporting its output directory"
        )
    print(
        f"swift package dump-symbol-graph output: {graph_dir} (exit status {dump_status})",
        file=sys.stderr,
    )

    observed_graph_modules = {
        json.loads(path.read_text())["module"]["name"]
        for path in sorted(graph_dir.rglob("*.symbols.json"))
    }
    if platform.system() == "Darwin":
        # SwiftPM skips some Apple-only modules, so re-extract them (and
        # PKContracts for its cross-module relationships) to keep the stable
        # surface complete.
        fallback_modules = sorted({*set(modules) - observed_graph_modules, "PKContracts"})
        for module in fallback_modules:
            for graph in graph_dir.rglob("*.symbols.json"):
                if json.loads(graph.read_text())["module"]["name"] == module:
                    graph.unlink()
        extract_graphs(fallback_modules, bin_path, graph_dir, include_spi=False)

    symbols, relationships, observed_modules = read_graphs(graph_dir, modules)
    missing = sorted(set(modules) - observed_modules)
    if missing:
        if dump_status:
            print(dump_output, end="", file=sys.stderr)
        raise SystemExit("missing public symbol graphs: " + ", ".join(missing))
    if dump_status:
        print(
            "swift package dump-symbol-graph reported non-public-target errors; "
            "all catalog public symbol graphs were emitted",
            file=sys.stderr,
        )

    return {
        "schemaVersion": 2,
        "release": BASELINE_RELEASE,
        "platform": PLATFORM,
        "modules": modules,
        "symbols": [dict(precise=precise, **symbols[precise]) for precise in sorted(symbols)],
        "relationships": [relationships[key] for key in sorted(relationships)],
    }


def experimental_delta(stable: dict, full: dict) -> dict:
    stable_precise = {s["precise"] for s in stable["symbols"]}
    stable_rel_keys = {
        json.dumps(r, sort_keys=True) for r in stable["relationships"]
    }
    spi_symbols = [s for s in full["symbols"] if s["precise"] not in stable_precise]
    spi_relationships = [
        r for r in full["relationships"]
        if json.dumps(r, sort_keys=True) not in stable_rel_keys
    ]
    return {
        "schemaVersion": 2,
        "release": BASELINE_RELEASE,
        "platform": PLATFORM,
        "modules": stable["modules"],
        "symbols": spi_symbols,
        "relationships": spi_relationships,
    }


def label(symbol: dict) -> str:
    return f"{symbol['module']}.{'/'.join(symbol['path'])}"


def check_baseline(baseline_path: Path, actual: dict, name: str) -> int:
    if not baseline_path.exists():
        print(f"{name.lower()} baseline is missing: {baseline_path.relative_to(ROOT)}", file=sys.stderr)
        return 1
    expected = json.loads(baseline_path.read_text())
    if expected == actual:
        print(f"{name} matches {baseline_path.relative_to(ROOT)} ({len(actual['symbols'])} symbols).")
        return 0

    expected_symbols = {symbol["precise"]: symbol for symbol in expected.get("symbols", [])}
    actual_symbols = {symbol["precise"]: symbol for symbol in actual["symbols"]}
    removed = sorted(set(expected_symbols) - set(actual_symbols))
    added = sorted(set(actual_symbols) - set(expected_symbols))
    changed = sorted(
        precise for precise in set(expected_symbols) & set(actual_symbols)
        if expected_symbols[precise] != actual_symbols[precise]
    )
    expected_relationships = {
        json.dumps(relationship, sort_keys=True)
        for relationship in expected.get("relationships", [])
    }
    actual_relationships = {
        json.dumps(relationship, sort_keys=True)
        for relationship in actual["relationships"]
    }
    print(
        f"{name} differs from the reviewed baseline {baseline_path.relative_to(ROOT)}.",
        file=sys.stderr,
    )
    for heading, identifiers, source in (
        ("removed", removed, expected_symbols),
        ("added", added, actual_symbols),
        ("changed", changed, actual_symbols),
    ):
        for precise in identifiers[:50]:
            print(f"  {heading}: {label(source[precise])}", file=sys.stderr)
        if len(identifiers) > 50:
            print(f"  {heading}: ... and {len(identifiers) - 50} more", file=sys.stderr)
    for heading, relationships in (
        ("removed relationship", expected_relationships - actual_relationships),
        ("added relationship", actual_relationships - expected_relationships),
    ):
        for relationship in sorted(relationships)[:50]:
            print(f"  {heading}: {relationship}", file=sys.stderr)
        if len(relationships) > 50:
            print(f"  {heading}: ... and {len(relationships) - 50} more", file=sys.stderr)
    print("Review the change, then run `make update-public-api-baseline` if it is intentional.", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()

    stable = inventory(include_spi=False)
    full = inventory(include_spi=True)
    experimental = experimental_delta(stable, full)

    if args.write:
        for baseline_path, actual in (
            (PRIMARY_BASELINE, stable),
            (EXPERIMENTAL_BASELINE, experimental),
        ):
            baseline_path.parent.mkdir(parents=True, exist_ok=True)
            baseline_path.write_text(json.dumps(actual, indent=2, sort_keys=False) + "\n")
            print(f"Wrote {baseline_path.relative_to(ROOT)} ({len(actual['symbols'])} symbols).")
        return 0

    stable_status = check_baseline(PRIMARY_BASELINE, stable, "Public API")
    experimental_status = check_baseline(EXPERIMENTAL_BASELINE, experimental, "Experimental API")
    return 1 if (stable_status != 0 or experimental_status != 0) else 0


if __name__ == "__main__":
    raise SystemExit(main())
