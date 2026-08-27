#!/usr/bin/env python3
"""Generate or verify the reviewed public Swift symbol inventory."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
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


def target_release() -> str:
    """Return the major.minor release represented by the Next API surface."""
    catalog = json.loads(CATALOG.read_text())
    version = catalog["next"].get("version")
    if not version:
        raise SystemExit("docs/catalog.json next.version is required for public API baselines")
    return ".".join(version.split(".")[:2])


BASELINE_RELEASE = target_release()
BASELINE = ROOT / "api" / f"{BASELINE_RELEASE}-public-api-{PLATFORM}.json"


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


def inventory() -> dict:
    modules = public_modules()
    bin_path = Path(run("swift", "build", "--show-bin-path").splitlines()[-1])
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

    graph_paths = sorted(graph_dir.rglob("*.symbols.json"))
    observed_graph_modules = {
        json.loads(path.read_text())["module"]["name"]
        for path in graph_paths
    }
    if platform.system() == "Darwin":
        generated_module_maps = bin_path.parent.parent / "Intermediates.noindex" / "GeneratedModuleMaps"
        sdk = run("xcrun", "--show-sdk-path")
        fallback_modules = set(modules) - observed_graph_modules
        fallback_modules.add("PKContracts")
        for module in sorted(fallback_modules):
            for graph in graph_dir.rglob("*.symbols.json"):
                if json.loads(graph.read_text())["module"]["name"] == module:
                    graph.unlink()
            candidates = list(bin_path.parent.parent.rglob(f"{module}.swiftmodule"))
            if not candidates:
                continue
            run(
                "xcrun", "swift-symbolgraph-extract",
                "-module-name", module,
                "-I", str(candidates[0].parent),
                "-I", str(generated_module_maps),
                "-sdk", sdk,
                "-output-dir", str(graph_dir),
                "-minimum-access-level", "public",
                "-skip-synthesized-members",
                "-skip-inherited-docs",
            )

    symbols: dict[str, dict] = {}
    relationships: dict[str, dict] = {}
    observed_modules: set[str] = set()
    for graph_path in sorted(graph_dir.rglob("*.symbols.json")):
        graph = json.loads(graph_path.read_text())
        module = graph["module"]["name"]
        if module not in modules:
            continue
        observed_modules.add(module)
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
            key = json.dumps(entry, sort_keys=True)
            relationships[key] = entry

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


def label(symbol: dict) -> str:
    return f"{symbol['module']}.{'/'.join(symbol['path'])}"


def check(actual: dict) -> int:
    if not BASELINE.exists():
        print(f"public API baseline is missing: {BASELINE.relative_to(ROOT)}", file=sys.stderr)
        return 1
    expected = json.loads(BASELINE.read_text())
    if expected == actual:
        print(f"Public API matches {BASELINE.relative_to(ROOT)} ({len(actual['symbols'])} symbols).")
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
    print(f"Public API differs from the reviewed {BASELINE_RELEASE} baseline.", file=sys.stderr)
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
    actual = inventory()
    if args.write:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(json.dumps(actual, indent=2, sort_keys=False) + "\n")
        print(f"Wrote {BASELINE.relative_to(ROOT)} ({len(actual['symbols'])} symbols).")
        return 0
    return check(actual)


if __name__ == "__main__":
    raise SystemExit(main())
