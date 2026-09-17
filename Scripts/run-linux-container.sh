#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/run-linux-container.sh [options] -- command [args...]

Options:
  --build-only       Build the pinned Linux development image and exit.
  --lock PATH        Serialize the container run with a host-side file lock.
  --log PATH         Write combined output to PATH while preserving the exit status.
  --scratch PATH     Mount PATH at /scratch for isolated SwiftPM builds.

Environment:
  LINUX_SWIFT_VERSION  Swift toolchain baked into the image (default 6.4.0).
                       It selects the swift:<version>-noble base image via the
                       SWIFT_VERSION build argument and, unless LINUX_IMAGE is
                       set, the positronickit-linux-dev-<version> image tag.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Podman is the preferred runtime; Docker is an equally supported alternative.
# CONTAINER_RUNTIME pins an explicit binary and disables auto-detection.
container_runtime="${CONTAINER_RUNTIME:-}"
# The toolchain selects both the default image tag and the swift:<version> base
# image. Default to the supported lane so a direct script run matches `make`.
# Do not read the generic SWIFT_VERSION: the swift:<version> base images export
# it (for example `swift-6.4.0-RELEASE`), which is not a valid version or tag.
linux_swift_version="${LINUX_SWIFT_VERSION:-6.4.0}"
linux_image="${LINUX_IMAGE:-positronickit-linux-dev-$linux_swift_version}"
git_common_dir=""
build_only=0
lock_path=""
log_path=""
scratch_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-only)
      build_only=1
      shift
      ;;
    --lock)
      lock_path="${2:?--lock requires a path}"
      shift 2
      ;;
    --log)
      log_path="${2:?--log requires a path}"
      shift 2
      ;;
    --scratch)
      scratch_path="${2:?--scratch requires a path}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'run-linux-container: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$build_only" -eq 0 ] && [ "$#" -eq 0 ]; then
  printf 'run-linux-container: a command is required after --\n' >&2
  usage >&2
  exit 2
fi

# Prints the runtime's own name, used to select runtime-specific flags. The
# probe reads `--version` output rather than the binary's filename so an
# explicit CONTAINER_RUNTIME path still gets the right flags.
runtime_flavor() {
  case "$("$1" --version 2>/dev/null | head -n1)" in
    [Pp]odman*) printf 'podman\n' ;;
    *) printf 'docker\n' ;;
  esac
}

# Reports whether the runtime is reachable, capturing its diagnostic in
# $probe_error for the caller to surface.
runtime_is_usable() {
  "$1" info >/dev/null 2>"$probe_error"
}

require_runtime_unavailable_hint() {
  printf 'PositronicKit Linux testing requires Podman or Docker; no native Linux fallback is supported.\n' >&2
  printf 'Install Podman (preferred) or Docker, or set CONTAINER_RUNTIME=/absolute/path/to/runtime.\n' >&2
}

report_blocked_runtime() {
  printf '%s is installed but unavailable to this process:\n' "$1" >&2
  sed 's/^/  /' "$probe_error" >&2
  printf '\nIf an agent sandbox blocked the container runtime, rerun the same make command with escalated container-runtime permissions.\n' >&2
}

# Resolves the container runtime into $runtime_path, preferring an explicit
# CONTAINER_RUNTIME, then Podman, then Docker.
resolve_runtime() {
  local candidate
  local candidate_path
  local blocked_name=""

  if [ -n "$container_runtime" ]; then
    if ! candidate_path="$(command -v "$container_runtime" 2>/dev/null)"; then
      printf "CONTAINER_RUNTIME='%s' is not an executable container runtime.\n" \
        "$container_runtime" >&2
      require_runtime_unavailable_hint
      return 1
    fi
    if ! runtime_is_usable "$candidate_path"; then
      report_blocked_runtime "$candidate_path"
      return 1
    fi
    runtime_path="$candidate_path"
    return 0
  fi

  for candidate in podman docker; do
    if ! candidate_path="$(command -v "$candidate" 2>/dev/null)"; then
      continue
    fi
    if runtime_is_usable "$candidate_path"; then
      runtime_path="$candidate_path"
      return 0
    fi
    # Remember the first installed-but-unreachable runtime so a sandboxed
    # Podman still produces the escalation hint instead of "not installed".
    if [ -z "$blocked_name" ]; then
      blocked_name="$candidate_path"
    fi
  done

  if [ -n "$blocked_name" ]; then
    report_blocked_runtime "$blocked_name"
    return 1
  fi

  require_runtime_unavailable_hint
  return 1
}

run_gate() {
  local runtime_path=""
  local runtime_error
  local flavor
  local -a run_command

  runtime_error="$(mktemp)"
  probe_error="$runtime_error"

  if ! resolve_runtime; then
    rm -f "$runtime_error"
    return 1
  fi
  rm -f "$runtime_error"

  flavor="$(runtime_flavor "$runtime_path")"

  printf 'Building Linux development image %s with %s...\n' "$linux_image" "$flavor"
  "$runtime_path" build -t "$linux_image" \
    --build-arg "SWIFT_VERSION=$linux_swift_version" \
    -f "$repo_root/.devcontainer/Dockerfile" "$repo_root"

  if [ "$build_only" -eq 1 ]; then
    return 0
  fi

  if [ -f "$repo_root/.git" ]; then
    if ! git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" \
      || [ ! -d "$git_common_dir" ]; then
      printf 'run-linux-container: could not resolve the linked worktree Git directory\n' >&2
      return 1
    fi
  fi

  run_command=(
    "$runtime_path" run --rm
  )

  # --userns=keep-id is Podman-only. Docker maps --user directly onto the host
  # uid/gid, so the bind-mounted checkout stays host-owned either way.
  if [ "$flavor" = "podman" ]; then
    run_command+=(--userns=keep-id)
  fi

  run_command+=(
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -v "$repo_root:/workspace:Z"
    -w /workspace
  )

  if [ -n "$git_common_dir" ]; then
    # Use the shared z label here; a private Z relabel would break the host checkout.
    run_command+=(-v "$git_common_dir:$git_common_dir:ro,z")
  fi

  if [ -n "${LINUX_TEST_FILTER:-}" ]; then
    run_command+=(-e "LINUX_TEST_FILTER=$LINUX_TEST_FILTER")
  fi
  if [ -n "${LINUX_TEST_TRAITS:-}" ]; then
    run_command+=(-e "LINUX_TEST_TRAITS=$LINUX_TEST_TRAITS")
  fi
  if [ -n "$scratch_path" ]; then
    mkdir -p "$scratch_path"
    scratch_path="$(cd "$scratch_path" && pwd -P)"
    run_command+=(-v "$scratch_path:/scratch:Z")
  fi

  run_command+=("$linux_image" "$@")

  if [ -n "$lock_path" ]; then
    if ! command -v flock >/dev/null 2>&1; then
      printf 'run-linux-container: flock is required to protect shared SwiftPM build state\n' >&2
      return 1
    fi
    mkdir -p "$(dirname "$lock_path")"
    printf 'Waiting for Linux test lock %s...\n' "$lock_path"
    flock -w 900 "$lock_path" "${run_command[@]}"
  else
    "${run_command[@]}"
  fi
}

if [ -n "$log_path" ]; then
  mkdir -p "$(dirname "$log_path")"
  set +e
  (set -e; run_gate "$@") 2>&1 | tee "$log_path"
  status="${PIPESTATUS[0]}"
  set -e
  exit "$status"
fi

run_gate "$@"
