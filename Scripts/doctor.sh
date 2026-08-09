#!/usr/bin/env bash
# doctor.sh — preflight prerequisite check for PositronicKit.
#
# Reports the presence (and version, where useful) of every tool the Makefile
# gates depend on: Swift, Rust, the C/C++ toolchain, pkg-config, OpenSSL dev
# headers, curl, shasum, a container runtime (Docker/Podman), and the pinned
# MiniLM model assets. Missing items print an actionable hint so the operator
# knows whether they matter for the gate they intend to run.
#
# Exits non-zero only when a *required* prerequisite (the Swift toolchain) is
# absent; missing optional prerequisites are reported as warnings. Invoked by
# `make doctor`, which passes its derived CONTAINER_RUNTIME and PKFASTEMBED_PREFIX
# so the report reflects the Makefile's own configuration. The script itself
# does not require Swift to run (parse-time discovery was removed in PKRR-026).
set -euo pipefail

container_runtime="${1:-}"
pkfastembed_prefix="${2:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/native/pkfastembed/model-assets.sha256"

green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; dim=$'\033[2m'; reset=$'\033[0m'
if [ ! -t 1 ]; then green=""; yellow=""; red=""; dim=""; reset=""; fi

ok()   { printf "  ${green}ok${reset}   %s\n" "$1"; }
miss() { printf "  ${yellow}MISS${reset} %s\n" "$1"; }
hint() { printf "        ${dim}%s${reset}\n" "$1"; }

missing_required=0

printf "PositronicKit prerequisite report\n"
printf "  host: %s %s\n\n" "$(uname -s)" "$(uname -m)"

# --- Swift (required for every Swift gate) ----------------------------------
required_swift_version="$(sed -nE 's|^// swift-tools-version:[[:space:]]*([0-9]+\.[0-9]+).*|\1|p' "$repo_root/Package.swift" | head -n1)"
required_swift_major="${required_swift_version%%.*}"
required_swift_minor="${required_swift_version#*.}"

if [ -z "$required_swift_version" ]; then
  miss "Swift tools version could not be read from Package.swift"
  hint "Required for all Swift gates: use the Swift version declared by Package.swift."
  missing_required=1
elif command -v swift >/dev/null 2>&1; then
  swift_requirement_hint="Required for all Swift gates: Swift ${required_swift_version}+ via https://swift.org/install (swiftly is easiest)."
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
      ok "Swift: $swift_display"
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

# --- Rust (required for PKFastEmbed / MiniLM) -------------------------------
if command -v cargo >/dev/null 2>&1; then
  ok "Rust: $(cargo --version 2>/dev/null || echo unknown)"
else
  miss "Rust toolchain (cargo) not found on PATH"
  hint "Only needed for PKFastEmbed/MiniLM. Install via https://rustup.rs (stable)."
fi

# --- C/C++ toolchain (required to link PKFastEmbed) -------------------------
cc_bin=""
for c in cc gcc clang; do
  if command -v "$c" >/dev/null 2>&1; then cc_bin="$c"; break; fi
done
if [ -n "$cc_bin" ]; then
  ok "C/C++: $cc_bin -> $("$cc_bin" --version 2>/dev/null | head -n1 || echo unknown)"
else
  miss "C/C++ compiler (cc/gcc/clang) not found on PATH"
  hint "Only needed for PKFastEmbed/MiniLM. Install gcc/g++ or clang."
fi

# --- pkg-config (required for CPKFastEmbed systemLibrary) -------------------
if command -v pkg-config >/dev/null 2>&1; then
  ok "pkg-config: $(pkg-config --version 2>/dev/null || echo unknown)"
else
  miss "pkg-config not found on PATH"
  hint "Only needed for PKFastEmbed/MiniLM. Debian/Ubuntu: pkg-config ; macOS: brew install pkg-config."
fi

# --- OpenSSL dev headers (required for fastembed native-tls) ----------------
if command -v pkg-config >/dev/null 2>&1 && pkg-config openssl >/dev/null 2>&1; then
  ok "OpenSSL: $(pkg-config --modversion openssl 2>/dev/null || echo present)"
else
  miss "OpenSSL development headers not visible to pkg-config"
  hint "Only needed for PKFastEmbed/MiniLM. Debian/Ubuntu: libssl-dev ; Fedora: openssl-devel ; macOS: ships with the system."
fi

# --- curl (required for first model-asset download) ------------------------
if command -v curl >/dev/null 2>&1; then
  ok "curl: $(curl --version 2>/dev/null | head -n1 | awk '{print $1, $2}' || echo unknown)"
else
  miss "curl not found on PATH"
  hint "Only needed for the first MiniLM bootstrap. Install curl."
fi

# --- shasum (required for asset checksum verification) ----------------------
if command -v shasum >/dev/null 2>&1; then
  ok "shasum: $(shasum --version 2>/dev/null | head -n1 || echo present)"
else
  miss "shasum not found on PATH"
  hint "Only needed for MiniLM. macOS ships shasum; Linux: install perl Digest::SHA (e.g. libdigest-sha-perl)."
fi

# --- Container runtime (required for linux-* targets) ----------------------
if [ -n "$container_runtime" ] && command -v "$container_runtime" >/dev/null 2>&1; then
  ok "Container runtime: $container_runtime ($("$container_runtime" --version 2>/dev/null | head -n1 || echo unknown))"
else
  miss "Container runtime not found (CONTAINER_RUNTIME='${container_runtime:-<empty>}')"
  hint "Required for 'make linux-image/linux-build/linux-test'. Install podman or docker,"
  hint "or set CONTAINER_RUNTIME=/path/to/runtime."
fi

# --- MiniLM model asset pin -------------------------------------------------
if [ -f "$manifest" ]; then
  model_sha="$(awk '$2 == "model.onnx" { print $1 }' "$manifest" 2>/dev/null || true)"
  if [ -n "$model_sha" ]; then
    ok "MiniLM model.onnx pin: ${model_sha:0:16}... (native/pkfastembed/model-assets.sha256)"
  else
    miss "model-assets.sha256 present but has no model.onnx entry"
    hint "The pin file is malformed; expected '<sha256> model.onnx' lines."
  fi
else
  miss "native/pkfastembed/model-assets.sha256 not found"
  hint "Ships with the repo; check your checkout / git status."
fi

# --- PKFastEmbed native prefix (built by bootstrap-minilm) -----------------
if [ -n "$pkfastembed_prefix" ] && [ -d "$pkfastembed_prefix/lib" ]; then
  ok "PKFastEmbed native prefix present: $pkfastembed_prefix"
else
  miss "PKFastEmbed native prefix not built at ${pkfastembed_prefix:-<empty>}"
  hint "Only needed for MiniLM gates. 'make verify-minilm' bootstraps it idempotently."
fi

printf "\n"
if [ "$missing_required" -ne 0 ]; then
  printf "%sRequired prerequisites missing — fix the items above before running Swift gates.%s\n" "$red" "$reset"
  exit 1
fi
printf "%sAll required prerequisites present. Items flagged above are optional for specific gates.%s\n" "$green" "$reset"
