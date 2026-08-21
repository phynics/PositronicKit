#!/usr/bin/env python3
"""Validate the documentation catalog, package products, pins, and local links."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
CATALOG = json.loads((ROOT / "docs/catalog.json").read_text(encoding="utf-8"))
ERRORS: list[str] = []


def error(message: str) -> None:
    ERRORS.append(message)


def github_slug(heading: str) -> str:
    value = heading.strip().lower()
    value = re.sub(r"<[^>]+>", "", value)
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return value.replace(" ", "-")


def validate_catalog() -> None:
    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    manifest_libraries = set(re.findall(r'\.library\(name:\s*"([^"]+)"', package))
    manifest_executables = set(re.findall(r'\.executable\(name:\s*"([^"]+)"', package))
    products = CATALOG["products"]
    catalog_names = {item["name"] for item in products}
    manifest_names = manifest_libraries | manifest_executables
    if catalog_names != manifest_names:
        error(f"product catalog differs from Package.swift: missing={sorted(manifest_names - catalog_names)}, extra={sorted(catalog_names - manifest_names)}")

    consumer_source = (ROOT / "Tests/PublicProductConsumer/main.swift").read_text(encoding="utf-8")
    consumer_imports = set(re.findall(r"^import\s+(\w+)", consumer_source, flags=re.MULTILINE))
    consumer_target = re.search(
        r'\.executableTarget\(\s*name:\s*"PublicProductConsumer"(?P<body>.*?)\n\s*\),',
        package,
        flags=re.DOTALL,
    )
    consumer_dependencies = set(re.findall(r'"([A-Za-z][A-Za-z0-9]+)"', consumer_target.group("body") if consumer_target else ""))
    for product in products:
        docs_path = ROOT / product["docs"]
        if not docs_path.exists():
            error(f"{product['name']} references missing documentation: {product['docs']}")
        if product["kind"] == "library":
            if not product.get("docc"):
                error(f"library product lacks DocC coverage: {product['name']}")
            if product["module"] not in consumer_imports:
                error(f"PublicProductConsumer does not import {product['module']}")
            if product["name"] not in consumer_dependencies:
                error(f"PublicProductConsumer target does not depend on {product['name']}")
            symbol = product.get("consumerSymbol")
            if not symbol or symbol not in consumer_source:
                error(f"PublicProductConsumer does not exercise a cataloged symbol for {product['name']}")

    for guide in CATALOG["guides"]:
        if not (ROOT / guide["path"]).exists():
            error(f"catalog guide path does not exist: {guide['path']}")


def validate_release_channels() -> None:
    stable = CATALOG["stable"]["version"]
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    pins = set(re.findall(r'\.package\([^\n]+from:\s*"([0-9]+\.[0-9]+\.[0-9]+)"', readme))
    if pins != {stable}:
        error(f"README SwiftPM pin must be exactly stable {stable}; found {sorted(pins)}")
    for phrase in (f"Latest stable: `{stable}`", "Next / v4"):
        if phrase not in readme:
            error(f"README does not clearly declare release channel: {phrase}")
    try:
        tag = subprocess.run(
            ["git", "tag", "--list", CATALOG["stable"]["ref"]],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if tag != CATALOG["stable"]["ref"]:
            error(f"stable documentation ref is not a local Git tag: {CATALOG['stable']['ref']}")
        else:
            for guide in CATALOG["stable"]["guides"]:
                tagged_path = f"{tag}:{guide['path'].rstrip('/')}"
                result = subprocess.run(
                    ["git", "cat-file", "-e", tagged_path],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    error(f"stable guide is missing from tag {tag}: {guide['path']}")
    except (OSError, subprocess.CalledProcessError) as exc:
        error(f"could not validate stable Git tag: {exc}")


def markdown_files() -> list[Path]:
    files = [ROOT / "README.md", ROOT / "AGENTS.md", ROOT / "CONTEXT-MAP.md"]
    files += sorted((ROOT / "docs").rglob("*.md"))
    files += sorted((ROOT / "Sources").glob("*/CONTEXT.md"))
    return [path for path in files if path.exists()]


def validate_links() -> None:
    link_pattern = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
    for source in markdown_files():
        text = source.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            target = raw_target.split(maxsplit=1)[0].strip("<>")
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            path_part, _, fragment = target.partition("#")
            destination = source if not path_part else (source.parent / unquote(path_part)).resolve()
            try:
                destination.relative_to(ROOT)
            except ValueError:
                error(f"{source.relative_to(ROOT)} links outside repository: {target}")
                continue
            if not destination.exists():
                error(f"{source.relative_to(ROOT)} links to missing path: {target}")
                continue
            if fragment and destination.is_file() and destination.suffix.lower() == ".md":
                headings = {
                    github_slug(match.group(1))
                    for match in re.finditer(r"^#{1,6}\s+(.+?)\s*#*\s*$", destination.read_text(encoding="utf-8"), flags=re.MULTILINE)
                }
                if unquote(fragment).lower() not in headings:
                    error(f"{source.relative_to(ROOT)} links to missing anchor: {target}")


def validate_agent_and_pr_guidance() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    if "docs/catalog.json" not in agents:
        error("AGENTS.md must point documentation/product work to docs/catalog.json")
    template_path = ROOT / ".github/pull_request_template.md"
    if not template_path.exists() or "## Docs / ADR impact" not in template_path.read_text(encoding="utf-8"):
        error("pull request template must require a Docs / ADR impact declaration")


def validate_generated_channel_links() -> None:
    repository = CATALOG["repository"]
    channels = (
        ("stable", CATALOG["stable"]["ref"], CATALOG["stable"]["guides"], ROOT / "docs/index.html"),
        ("next", CATALOG["next"]["ref"], CATALOG["guides"], ROOT / "docs/next/index.html"),
    )
    for channel, ref, guides, landing_path in channels:
        landing = landing_path.read_text(encoding="utf-8") if landing_path.exists() else ""
        for guide in guides:
            path = guide["path"]
            kind = "tree" if path.endswith("/") else "blob"
            expected = f"https://github.com/{repository}/{kind}/{ref}/{path.rstrip('/')}"
            if expected not in landing:
                error(f"{channel} landing lacks canonical {kind} link for {path}")


validate_catalog()
validate_release_channels()
validate_links()
validate_agent_and_pr_guidance()
validate_generated_channel_links()

if ERRORS:
    print("documentation validation failed:", file=sys.stderr)
    for item in ERRORS:
        print(f"- {item}", file=sys.stderr)
    raise SystemExit(1)

print("documentation catalog, release channels, products, links, and anchors passed")
