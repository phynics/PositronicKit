#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/run-linux-container.sh [options] -- command [args...]

Options:
  --build-only       Build the pinned Linux development image and exit.
  --lock PATH        Serialize runs that share this writable resource.
  --log PATH         Write combined output to PATH while preserving the exit status.
  --scratch PATH     Mount PATH at /scratch for a SwiftPM build.
  --scratch-root PATH  Build a per-worktree warm or isolated scratch below PATH.
  --mode MODE        Select warm (default) or isolated scratch behavior.
  --run-id ID        Set a safe, unique identity for this invocation.
  --metadata PATH    Write per-run timing and status data to PATH.
  --read-only-workspace  Mount the source checkout read-only.
  --timeout SECONDS  Set the container command deadline.
  --max-concurrent N Cap concurrent host agent commands.

Environment:
  LINUX_SWIFT_VERSION  Swift toolchain baked into the image (default 6.4.0).
                       It selects the swift:<version>-noble base image via the
                       SWIFT_VERSION build argument and, unless LINUX_IMAGE is
                       set, the positronickit-linux-dev-<version> image tag.
  AGENT_TEST_MODE      Default focused-test scratch mode (warm or isolated).
  AGENT_SWIFT_JOBS     Swift compiler jobs per run (default 1).
  AGENT_MAX_CONCURRENT_RUNS  Host-wide agent command slots (default 3).
  AGENT_RUN_TIMEOUT    Container command deadline in seconds (default 7200).
  AGENT_MEMORY_SAMPLE_INTERVAL  Retry delay for container stats (default 2 seconds).
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Podman is the preferred runtime; Docker is an equally supported alternative.
# CONTAINER_RUNTIME pins an explicit binary and disables auto-detection.
container_runtime="${CONTAINER_RUNTIME:-}"
# The toolchain selects both the default image tag and the swift:<version> base
# image. Default to the current lane so a direct script run matches `make`.
# Do not read the generic SWIFT_VERSION: the swift:<version> base images export
# it (for example `swift-6.4.0-RELEASE`), which is not a valid version or tag.
linux_swift_version="${LINUX_SWIFT_VERSION:-6.4.0}"
linux_image="${LINUX_IMAGE:-positronickit-linux-dev-$linux_swift_version}"
git_common_dir=""
build_only=0
lock_path=""
log_path=""
scratch_path=""
scratch_root="${AGENT_SCRATCH_ROOT:-}"
mode="${AGENT_TEST_MODE:-warm}"
metadata_path=""
logs_root="${AGENT_LOG_DIR:-$repo_root/.build/agent-logs}"
metadata_root="${AGENT_METADATA_DIR:-$repo_root/.build/agent-metadata}"
run_id=""
worktree_id=""
read_only_workspace=0
run_timeout="${AGENT_RUN_TIMEOUT:-7200}"
image_timeout="${AGENT_IMAGE_BUILD_TIMEOUT:-1200}"
lock_timeout="${AGENT_LOCK_TIMEOUT:-7200}"
max_concurrent="${AGENT_MAX_CONCURRENT_RUNS:-3}"
swift_jobs="${AGENT_SWIFT_JOBS:-1}"
memory_sample_interval="${AGENT_MEMORY_SAMPLE_INTERVAL:-2}"
agent_slot_dir="${AGENT_SLOT_DIR:-${TMPDIR:-/tmp}/positronickit-agent-slots-$(id -u)}"
active_container_name=""
active_container_token=""
active_runtime_path=""
active_helper_pid=""
run_started_ns=""

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
    --scratch)
      scratch_path="${2:?--scratch requires a path}"
      shift 2
      ;;
    --scratch-root)
      scratch_root="${2:?--scratch-root requires a path}"
      shift 2
      ;;
    --mode)
      mode="${2:?--mode requires warm or isolated}"
      shift 2
      ;;
    --metadata)
      metadata_path="${2:?--metadata requires a path}"
      shift 2
      ;;
    --log)
      log_path="${2:?--log requires a path}"
      shift 2
      ;;
    --read-only-workspace)
      read_only_workspace=1
      shift
      ;;
    --timeout)
      run_timeout="${2:?--timeout requires seconds}"
      shift 2
      ;;
    --max-concurrent)
      max_concurrent="${2:?--max-concurrent requires a count}"
      shift 2
      ;;
    --run-id)
      run_id="${2:?--run-id requires an id}"
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

if [ "$mode" != warm ] && [ "$mode" != isolated ]; then
  printf 'run-linux-container: mode must be warm or isolated, got %s\n' "$mode" >&2
  exit 2
fi

if [ "$build_only" -eq 0 ] && [ "$#" -eq 0 ]; then
  printf 'run-linux-container: a command is required after --\n' >&2
  usage >&2
  exit 2
fi

if [[ ! "$max_concurrent" =~ ^[1-9][0-9]*$ ]]; then
  printf 'run-linux-container: AGENT_MAX_CONCURRENT_RUNS must be a positive integer\n' >&2
  exit 2
fi

if [ -z "$run_id" ]; then
  run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"
fi
if [[ ! "$run_id" =~ ^[A-Za-z0-9_.-]+$ ]] || [ "$run_id" = . ] || [ "$run_id" = .. ] || [ "${#run_id}" -gt 64 ]; then
  printf 'run-linux-container: run id must contain only letters, numbers, dot, underscore, or hyphen\n' >&2
  exit 2
fi
worktree_slug="$(basename "$repo_root" | tr -cs 'A-Za-z0-9_.-' '-')"
worktree_slug="${worktree_slug:0:24}"
worktree_hash="$(printf '%s' "$repo_root" | shasum -a 256 | cut -c1-12)"
worktree_id="${worktree_slug:-worktree}-$worktree_hash"
container_name="pk-agent-${worktree_id}-${run_id}"
container_token="${run_id}-$$-$RANDOM"
if [ -z "$log_path" ]; then
  log_path="$logs_root/$worktree_id/$run_id/agent.log"
fi
if [ -z "$metadata_path" ]; then
  metadata_path="$metadata_root/$worktree_id/$run_id/run.tsv"
fi
mkdir -p "$(dirname "$log_path")" "$(dirname "$metadata_path")"
: > "$metadata_path"
run_started_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
{
  printf 'run_id=%s\n' "$run_id"
  printf 'worktree_id=%s\n' "$worktree_id"
  printf 'mode=%s\n' "$mode"
  printf 'toolchain=%s\n' "$linux_swift_version"
  printf 'image=%s\n' "$linux_image"
  printf 'log_path=%s\n' "$log_path"
  printf 'metadata_path=%s\n' "$metadata_path"
  printf 'container_token=%s\n' "$container_token"
  printf 'max_concurrent_runs=%s\n' "$max_concurrent"
  printf 'swift_jobs=%s\n' "$swift_jobs"
  printf 'run_timeout_seconds=%s\n' "$run_timeout"
} >> "$metadata_path"

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

cleanup_container() {
  local labels
  if [ -n "$active_helper_pid" ]; then
    kill -TERM "$active_helper_pid" 2>/dev/null || true
    wait "$active_helper_pid" 2>/dev/null || true
    active_helper_pid=""
  fi
  if [ -n "$active_container_name" ] && [ -n "$active_runtime_path" ]; then
    labels="$("$active_runtime_path" inspect --format '{{ index .Config.Labels "org.positronickit.run-id" }} {{ index .Config.Labels "org.positronickit.worktree-id" }} {{ index .Config.Labels "org.positronickit.run-token" }}' "$active_container_name" 2>/dev/null || true)"
    if [ "$labels" = "$run_id $worktree_id $active_container_token" ]; then
      "$active_runtime_path" rm --force "$active_container_name" >/dev/null 2>&1 || true
    fi
    active_container_name=""
    active_container_token=""
  fi
}

run_helper() {
  "$@" &
  active_helper_pid="$!"
  wait "$active_helper_pid"
  local command_status="$?"
  active_helper_pid=""
  return "$command_status"
}

finalize() {
  local status="$?"
  local ended_ns
  local total_seconds
  trap - EXIT
  cleanup_container
  ended_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
  total_seconds="$(python3 -c 'import sys; print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000:.3f}")' "$run_started_ns" "$ended_ns")"
  {
    printf 'total_seconds=%s\n' "$total_seconds"
    printf 'exit_status=%s\n' "$status"
    printf 'finished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$metadata_path"
  exit "$status"
}

ensure_image() {
  local runtime_path="$1"
  local image_fingerprint
  local image_lock_hash
  local image_lock_path
  local image_script
  local dockerfile="$repo_root/.devcontainer/Dockerfile"

  image_fingerprint="$(
    {
      printf 'swift=%s\narchitecture=%s\n' "$linux_swift_version" "$(uname -m)"
      shasum -a 256 < "$dockerfile"
      if [ -f "$repo_root/.dockerignore" ]; then
        shasum -a 256 < "$repo_root/.dockerignore"
      else
        printf 'dockerignore=absent\n'
      fi
    } | shasum -a 256 | cut -c1-64
  )"
  image_lock_hash="$(printf '%s' "$linux_image" | shasum -a 256 | cut -c1-16)"
  image_lock_path="$agent_slot_dir/image-build-$image_lock_hash.lock"
  printf 'image_fingerprint=%s\n' "$image_fingerprint" >> "$metadata_path"

  image_script='set -euo pipefail
runtime="$1" image="$2" fingerprint="$3" swift_version="$4" dockerfile="$5" context="$6"
label_key=org.positronickit.dev-image-fingerprint
format="{{ index .Config.Labels \"$label_key\" }}"
current="$("$runtime" image inspect --format "$format" "$image" 2>/dev/null || true)"
if [ "$current" = "$fingerprint" ]; then
  printf "Reusing unchanged Linux development image %s (%s).\\n" "$image" "$fingerprint"
  exit 0
fi
printf "Building Linux development image %s; source fingerprint changed.\\n" "$image"
"$runtime" build -t "$image" --label "$label_key=$fingerprint" --build-arg "SWIFT_VERSION=$swift_version" -f "$dockerfile" "$context"'

  run_helper python3 "$repo_root/Scripts/with-agent-resources.py" \
    --resource-lock "$image_lock_path" \
    --slot-dir "$agent_slot_dir" \
    --max-concurrent "$max_concurrent" \
    --lock-timeout "$lock_timeout" \
    --timeout "$image_timeout" \
    --metadata "$metadata_path" \
    --phase image_setup \
    -- bash -c "$image_script" _ "$runtime_path" "$linux_image" \
      "$image_fingerprint" "$linux_swift_version" "$dockerfile" "$repo_root"
}

run_gate() {
  local runtime_path=""
  local runtime_error
  local flavor
  local resource_lock="$lock_path"
  local metadata_container_path="/run-meta/$(basename "$metadata_path")"
  local -a run_command
  local -a helper_arguments

  runtime_error="$(mktemp)"
  probe_error="$runtime_error"
  if ! resolve_runtime; then
    rm -f "$runtime_error"
    return 1
  fi
  rm -f "$runtime_error"
  active_runtime_path="$runtime_path"
  flavor="$(runtime_flavor "$runtime_path")"

  if [ -n "$scratch_root" ] && [ -z "$scratch_path" ]; then
    if [ "$mode" = warm ]; then
      scratch_path="$scratch_root/$worktree_id/warm"
    else
      scratch_path="$scratch_root/$worktree_id/$run_id"
    fi
  fi
  if [ "$mode" = isolated ] && [ "$build_only" -eq 0 ] && [ -z "$scratch_path" ]; then
    printf 'run-linux-container: isolated mode requires --scratch or --scratch-root\n' >&2
    return 2
  fi
  if [ -n "$scratch_path" ]; then
    mkdir -p "$scratch_path"
    scratch_path="$(cd "$scratch_path" && pwd -P)"
    printf 'scratch_path=%s\n' "$scratch_path" >> "$metadata_path"
    if [ "$mode" = warm ] && [ -z "$resource_lock" ]; then
      resource_lock="$scratch_path.lock"
    fi
  elif [ "$build_only" -eq 0 ] && [ "$mode" = warm ] && [ -z "$resource_lock" ]; then
    resource_lock="$repo_root/.build/positronickit-agent-gate.lock"
  fi
  printf 'resource_lock=%s\n' "${resource_lock:-none}" >> "$metadata_path"

  if ensure_image "$runtime_path"; then
    :
  else
    return $?
  fi
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
    "$runtime_path" run --rm --name "$container_name"
    --label "org.positronickit.run-id=$run_id"
    --label "org.positronickit.worktree-id=$worktree_id"
    --label "org.positronickit.run-token=$container_token"
  )

  # --userns=keep-id is Podman-only. Docker maps --user directly onto the host
  # uid/gid, so the bind-mounted checkout stays host-owned either way.
  if [ "$flavor" = podman ]; then
    run_command+=(--userns=keep-id)
  fi

  run_command+=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
  if [ "$read_only_workspace" -eq 1 ]; then
    run_command+=(-v "$repo_root:/workspace:ro,z")
  else
    run_command+=(-v "$repo_root:/workspace:Z")
  fi
  run_command+=(-w /workspace)

  if [ -n "$git_common_dir" ]; then
    # Use the shared z label here; a private Z relabel would break the host checkout.
    run_command+=(-v "$git_common_dir:$git_common_dir:ro,z")
  fi

  run_command+=(
    -e "AGENT_RUN_ID=$run_id"
    -e "AGENT_WORKTREE_ID=$worktree_id"
    -e "AGENT_EXECUTION_MODE=$mode"
    -e "AGENT_SWIFT_JOBS=$swift_jobs"
    -e "AGENT_METADATA_FILE=$metadata_container_path"
    -v "$(dirname "$metadata_path"):/run-meta:Z"
  )
  if [ -n "${LINUX_TEST_FILTER:-}" ]; then
    run_command+=(-e "LINUX_TEST_FILTER=$LINUX_TEST_FILTER")
  fi
  if [ -n "${LINUX_TEST_TRAITS:-}" ]; then
    run_command+=(-e "LINUX_TEST_TRAITS=$LINUX_TEST_TRAITS")
  fi
  if [ -n "${LINUX_TEST_REPETITIONS:-}" ]; then
    run_command+=(-e "LINUX_TEST_REPETITIONS=$LINUX_TEST_REPETITIONS")
  fi
  if [ -n "$scratch_path" ]; then
    run_command+=(-v "$scratch_path:/scratch:Z")
  fi
  run_command+=("$linux_image" "$@")

  active_container_name="$container_name"
  active_container_token="$container_token"
  helper_arguments=(
    --slot-dir "$agent_slot_dir"
    --max-concurrent "$max_concurrent"
    --lock-timeout "$lock_timeout"
    --timeout "$run_timeout"
    --metadata "$metadata_path"
    --phase container
    --sample-runtime "$runtime_path"
    --sample-container "$container_name"
    --memory-sample-interval "$memory_sample_interval"
  )
  if [ -n "$resource_lock" ]; then
    helper_arguments+=(--resource-lock "$resource_lock")
  fi
  printf 'Starting %s run %s; log: %s\n' "$mode" "$run_id" "$log_path"
  run_helper python3 "$repo_root/Scripts/with-agent-resources.py" \
    "${helper_arguments[@]}" -- "${run_command[@]}"
}

if [ -n "$log_path" ]; then
  exec > >(tee "$log_path") 2>&1
fi
trap 'exit 130' INT
trap 'exit 143' TERM
trap finalize EXIT
set +e
run_gate "$@"
status="$?"
set -e
exit "$status"
