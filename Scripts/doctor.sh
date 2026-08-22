#!/usr/bin/env bash
# doctor.sh — preflight prerequisite check for PositronicKit.
#
# Reports the presence (and version, where useful) of every tool the Makefile
# gates depend on. Linux verification is intentionally Podman-only, so host
# Swift and native dependencies are informational there; macOS verification
# requires a complete native Swift toolchain.
#
# Invoked by `make doctor`, which passes its Podman path so the report reflects
# the Makefile's own configuration. The script itself does not require Swift to run.
set -euo pipefail

podman_bin="${1:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; dim=$'\033[2m'; reset=$'\033[0m'
if [ ! -t 1 ]; then green=""; yellow=""; red=""; dim=""; reset=""; fi

ok()   { printf "  ${green}ok${reset}   %s\n" "$1"; }
miss() { printf "  ${yellow}MISS${reset} %s\n" "$1"; }
hint() { printf "        ${dim}%s${reset}\n" "$1"; }

missing_required=0
host_os="${DOCTOR_HOST_OS:-$(uname -s)}"

printf "PositronicKit prerequisite report\n"
printf "  host: %s %s\n\n" "$host_os" "$(uname -m)"

# --- Swift (required only for native macOS gates) ---------------------------
required_swift_version="$(sed -nE 's|^// swift-tools-version:[[:space:]]*([0-9]+\.[0-9]+).*|\1|p' "$repo_root/Package.swift" | head -n1)"
required_swift_major="${required_swift_version%%.*}"
required_swift_minor="${required_swift_version#*.}"
swift_requirement_hint="Native macOS gates require Swift ${required_swift_version:-6.1}+ with SwiftPM and Foundation."

if [ "$host_os" = "Linux" ]; then
  ok "Linux verification backend: Podman (host Swift is ignored)"
elif [ -z "$required_swift_version" ]; then
  miss "Swift tools version could not be read from Package.swift"
  hint "Required for all Swift gates: use the Swift version declared by Package.swift."
  missing_required=1
elif command -v swift >/dev/null 2>&1; then
  swift_version_output="$(swift --version 2>/dev/null || true)"
  swift_version="$(printf '%s\n' "$swift_version_output" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+)(\.[0-9]+)?.*/\1/p' | head -n1)"
  swift_display="$(printf '%s\n' "$swift_version_output" | head -n1)"
  swift_display="${swift_display:-unknown}"

  if [ -z "$swift_version" ]; then
    miss "Swift version is missing or unparseable (reported: $swift_display)"
    hint "$swift_requirement_hint"
    missing_required=1
  else
    swift_major="${swift_version%%.*}"
    swift_minor="${swift_version#*.}"
    swift_minor="${swift_minor%%.*}"
    if (( swift_major > required_swift_major ||
      (swift_major == required_swift_major && swift_minor >= required_swift_minor) )); then
      if ! swift package --version >/dev/null 2>&1; then
        miss "Swift reports $swift_version but SwiftPM is unavailable"
        hint "$swift_requirement_hint"
        missing_required=1
      elif ! swift -e 'import Foundation' >/dev/null 2>&1; then
        miss "Swift reports $swift_version but cannot import Foundation"
        hint "$swift_requirement_hint"
        missing_required=1
      else
        ok "Swift: $swift_display (SwiftPM and Foundation available)"
      fi
    else
      miss "Swift $swift_version is older than the required Swift $required_swift_version"
      hint "$swift_requirement_hint"
      missing_required=1
    fi
  fi
else
  miss "Swift toolchain not found on PATH"
  hint "$swift_requirement_hint"
  missing_required=1
fi

if [ "$host_os" = "Linux" ]; then
  ok "Swift and Python 3 supplied by the Podman image"
fi

# --- Podman (required for every Linux build/test entrypoint) ----------------
if [ -n "$podman_bin" ] && command -v "$podman_bin" >/dev/null 2>&1; then
  if [ "$host_os" = "Linux" ] && ! "$podman_bin" info >/dev/null 2>&1; then
    miss "Podman is installed but unavailable to this process"
    hint "If an agent sandbox blocked Podman, rerun the same make command with escalated container-runtime permissions."
    missing_required=1
  else
    ok "Podman: $podman_bin ($("$podman_bin" --version 2>/dev/null | head -n1 || echo unknown))"
  fi
else
  miss "Podman not found (PODMAN='${podman_bin:-<empty>}')"
  hint "Linux verification has no native or Docker fallback. Install Podman or set PODMAN=/absolute/path/to/podman."
  if [ "$host_os" = "Linux" ]; then missing_required=1; fi
fi

printf "\n"
if [ "$missing_required" -ne 0 ]; then
  printf "%sRequired prerequisites missing — fix the items above before running the selected platform gate.%s\n" "$red" "$reset"
  exit 1
fi
printf "%sAll required prerequisites present.%s\n" "$green" "$reset"
