#!/usr/bin/env python3
"""Require a concrete Docs / ADR impact declaration on pull requests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re


event_path = os.environ.get("GITHUB_EVENT_PATH")
if not event_path:
    print("PR docs-impact check skipped outside GitHub Actions")
    raise SystemExit(0)

event = json.loads(Path(event_path).read_text(encoding="utf-8"))
pull_request = event.get("pull_request")
if not pull_request:
    print("PR docs-impact check skipped for non-PR event")
    raise SystemExit(0)

body = pull_request.get("body") or ""
match = re.search(r"^## Docs / ADR impact\s*$\n(?P<body>.*?)(?=^##\s|\Z)", body, flags=re.MULTILINE | re.DOTALL)
declaration = re.sub(r"<!--.*?-->", "", match.group("body") if match else "", flags=re.DOTALL).strip()
if not declaration:
    print("Pull request body must contain a non-empty '## Docs / ADR impact' section.")
    raise SystemExit(1)

print("PR Docs / ADR impact declaration passed")
