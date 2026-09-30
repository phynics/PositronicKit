#!/usr/bin/env python3
"""Copy verified public API graphs to a new release line."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = ("linux", "macos")


def baseline_release(version: str) -> str:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"expected a bare semantic version, got {version!r}")
    return ".".join(version.split(".")[:2])


def promoted_document(
    document: dict[str, object],
    *,
    from_release: str,
    to_release: str,
    platform_name: str,
) -> dict[str, object]:
    if document.get("schemaVersion") != 2:
        raise ValueError(f"unsupported baseline schema for {platform_name}")
    if document.get("release") != from_release:
        raise ValueError(
            f"{platform_name} baseline release is {document.get('release')!r}, "
            f"expected {from_release!r}"
        )
    if document.get("platform") != platform_name:
        raise ValueError(
            f"baseline platform is {document.get('platform')!r}, expected {platform_name!r}"
        )
    if not isinstance(document.get("modules"), list):
        raise ValueError(f"{platform_name} baseline has no module inventory")
    if not isinstance(document.get("symbols"), list):
        raise ValueError(f"{platform_name} baseline has no symbol inventory")
    if not isinstance(document.get("relationships"), list):
        raise ValueError(f"{platform_name} baseline has no relationship inventory")

    promoted = dict(document)
    promoted["release"] = to_release
    return promoted


def write_atomically(path: Path, content: str) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary.write(content)
            temporary.write("\n")
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def promote_baselines(root: Path, from_version: str, to_version: str) -> list[Path]:
    from_release = baseline_release(from_version)
    to_release = baseline_release(to_version)
    if from_release == to_release:
        raise ValueError("source and target must use different major.minor release lines")

    planned: list[tuple[Path, dict[str, object]]] = []
    for platform_name in PLATFORMS:
        source = root / "api" / f"{from_release}-public-api-{platform_name}.json"
        destination = root / "api" / f"{to_release}-public-api-{platform_name}.json"
        try:
            document = json.loads(source.read_text(encoding="utf-8"))
        except OSError as exc:
            raise ValueError(f"cannot read {source.relative_to(root)}: {exc}") from exc
        if not isinstance(document, dict):
            raise ValueError(f"{source.relative_to(root)} must contain a JSON object")
        promoted = promoted_document(
            document,
            from_release=from_release,
            to_release=to_release,
            platform_name=platform_name,
        )

        if destination.exists():
            try:
                existing = json.loads(destination.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValueError(
                    f"cannot validate existing {destination.relative_to(root)}: {exc}"
                ) from exc
            if existing != promoted:
                raise ValueError(
                    f"refusing to overwrite a different baseline: {destination.relative_to(root)}"
                )
        else:
            planned.append((destination, promoted))

    for destination, document in planned:
        write_atomically(destination, json.dumps(document, indent=2))

    return [root / "api" / f"{to_release}-public-api-{platform}.json" for platform in PLATFORMS]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="from_version", required=True, help="verified source version")
    parser.add_argument("--to", dest="to_version", required=True, help="release version")
    arguments = parser.parse_args()

    try:
        destinations = promote_baselines(ROOT, arguments.from_version, arguments.to_version)
    except (OSError, ValueError) as exc:
        print(f"promote-public-api-baselines: {exc}", file=sys.stderr)
        return 1

    for destination in destinations:
        print(f"Verified baseline ready: {destination.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
