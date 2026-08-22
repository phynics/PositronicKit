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
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
podman_bin="${PODMAN:-podman}"
linux_image="${LINUX_IMAGE:-positronickit-linux-dev}"
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

run_gate() {
  local podman_path
  local runtime_error
  local -a run_command

  if ! podman_path="$(command -v "$podman_bin" 2>/dev/null)"; then
    printf 'PositronicKit Linux testing requires Podman; no native Linux fallback is supported.\n' >&2
    printf 'Install Podman or set PODMAN=/absolute/path/to/podman.\n' >&2
    return 1
  fi

  runtime_error="$(mktemp)"
  if ! "$podman_path" info >/dev/null 2>"$runtime_error"; then
    printf 'Podman is installed but unavailable to this process:\n' >&2
    sed 's/^/  /' "$runtime_error" >&2
    printf '\nIf an agent sandbox blocked Podman, rerun the same make command with escalated container-runtime permissions.\n' >&2
    rm -f "$runtime_error"
    return 1
  fi
  rm -f "$runtime_error"

  printf 'Building Linux development image %s...\n' "$linux_image"
  "$podman_path" build -t "$linux_image" -f "$repo_root/.devcontainer/Dockerfile" "$repo_root"

  if [ "$build_only" -eq 1 ]; then
    return 0
  fi

  run_command=(
    "$podman_path" run --rm --userns=keep-id
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -v "$repo_root:/workspace:Z"
    -w /workspace
  )

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
