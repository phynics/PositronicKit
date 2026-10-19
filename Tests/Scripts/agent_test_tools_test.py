#!/usr/bin/env python3
"""Regression tests for resource-scoped agent runs and focused Swift tests."""

from __future__ import annotations

import errno
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
RESOURCE_RUNNER = ROOT / "Scripts/with-agent-resources.py"
FOCUSED_RUNNER = ROOT / "Scripts/run-focused-agent-tests.py"


def load_resource_runner():
    spec = importlib.util.spec_from_file_location("with_agent_resources", RESOURCE_RUNNER)
    check(spec is not None and spec.loader is not None, "could not load resource runner")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def wait_for(path: Path, process: subprocess.Popen[str] | None = None) -> None:
    deadline = time.monotonic() + 3
    while not path.exists():
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(f"agent command exited before creating {path}: {stdout}\n{stderr}")
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {path}")
        time.sleep(0.01)


def blocked_command(started: Path, release: Path) -> list[str]:
    code = (
        "from pathlib import Path; import sys,time; "
        "Path(sys.argv[1]).write_text('started'); "
        "release=Path(sys.argv[2]); "
        "exec('while not release.exists():\\n time.sleep(0.01)')"
    )
    return [sys.executable, "-c", code, str(started), str(release)]


def start_resource_run(
    *,
    slot_dir: Path,
    max_concurrent: int,
    command: list[str],
    resource_lock: Path | None = None,
    timeout: str = "5",
    lock_timeout: str = "3",
    metadata: Path | None = None,
    sample_runtime: Path | None = None,
    sample_container: str | None = None,
    memory_sample_interval: str = "2",
) -> subprocess.Popen[str]:
    arguments = [
        sys.executable,
        str(RESOURCE_RUNNER),
        "--slot-dir",
        str(slot_dir),
        "--max-concurrent",
        str(max_concurrent),
        "--lock-timeout",
        lock_timeout,
        "--timeout",
        timeout,
    ]
    if resource_lock is not None:
        arguments.extend(["--resource-lock", str(resource_lock)])
    if metadata is not None:
        arguments.extend(["--metadata", str(metadata)])
    if sample_runtime is not None:
        arguments.extend(
            [
                "--sample-runtime",
                str(sample_runtime),
                "--sample-container",
                sample_container or "test-container",
                "--memory-sample-interval",
                memory_sample_interval,
            ]
        )
    arguments.extend(["--", *command])
    return subprocess.Popen(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def finish(process: subprocess.Popen[str], expected: int = 0) -> str:
    stdout, stderr = process.communicate(timeout=5)
    check(process.returncode == expected, f"expected exit {expected}, got {process.returncode}: {stdout}\n{stderr}")
    return stdout + stderr


def test_resource_locks_serialize_only_the_shared_resource() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        slot_dir = root / "slots"
        release = root / "release"
        first_started = root / "first.started"
        second_started = root / "second.started"
        first = start_resource_run(
            slot_dir=slot_dir,
            max_concurrent=2,
            resource_lock=root / "resource-a.lock",
            command=blocked_command(first_started, release),
        )
        wait_for(first_started, first)
        second = start_resource_run(
            slot_dir=slot_dir,
            max_concurrent=2,
            resource_lock=root / "resource-b.lock",
            command=blocked_command(second_started, release),
        )
        try:
            wait_for(second_started, second)
        finally:
            release.touch()
        finish(first)
        finish(second)


def test_same_resource_lock_blocks_the_second_writer() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        release = root / "release"
        first_started = root / "first.started"
        second_started = root / "second.started"
        lock = root / "shared.lock"
        first = start_resource_run(
            slot_dir=root / "slots",
            max_concurrent=2,
            resource_lock=lock,
            command=blocked_command(first_started, release),
        )
        wait_for(first_started, first)
        second = start_resource_run(
            slot_dir=root / "slots",
            max_concurrent=2,
            resource_lock=lock,
            command=[sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(second_started)],
        )
        try:
            time.sleep(0.2)
            check(not second_started.exists(), "the shared-resource writer bypassed its lock")
        finally:
            release.touch()
        finish(first)
        finish(second)
        check(second_started.exists(), "the waiting writer did not run after lock release")


def test_slot_cap_and_timeout_and_exit_status() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        release = root / "release"
        first_started = root / "first.started"
        second_started = root / "second.started"
        slots = root / "slots"
        first = start_resource_run(
            slot_dir=slots,
            max_concurrent=1,
            command=blocked_command(first_started, release),
        )
        wait_for(first_started, first)
        second = start_resource_run(
            slot_dir=slots,
            max_concurrent=1,
            command=[sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(second_started)],
        )
        try:
            time.sleep(0.2)
            check(not second_started.exists(), "the configured run-slot cap was exceeded")
        finally:
            release.touch()
        finish(first)
        finish(second)

        timed_out = start_resource_run(
            slot_dir=slots,
            max_concurrent=1,
            timeout="0.1",
            command=[sys.executable, "-c", "import time; time.sleep(10)"],
        )
        finish(timed_out, 124)

        failed = start_resource_run(
            slot_dir=slots,
            max_concurrent=1,
            command=[sys.executable, "-c", "raise SystemExit(23)"],
        )
        finish(failed, 23)


def test_cancellation_stops_the_child_and_records_status() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        child_pid_file = root / "child.pid"
        metadata = root / "run.tsv"
        child_code = (
            "from pathlib import Path; import os,sys,time; "
            "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        )
        process = start_resource_run(
            slot_dir=root / "slots",
            max_concurrent=1,
            command=[sys.executable, "-c", child_code, str(child_pid_file)],
            metadata=metadata,
        )
        wait_for(child_pid_file, process)
        child_pid = int(child_pid_file.read_text())
        process.send_signal(signal.SIGTERM)
        finish(process, 143)
        check("command_exit_status=143" in metadata.read_text(), "cancellation status was not recorded")
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("cancelled agent command left its child process running")


def test_command_spawn_retries_eperm_without_retrying_exec_errors() -> None:
    resource_runner = load_resource_runner()
    real_popen = subprocess.Popen
    attempts: list[dict[str, object]] = []

    def fail_twice(*arguments: object, **options: object) -> subprocess.Popen[bytes]:
        attempts.append(options)
        if len(attempts) <= 2:
            raise PermissionError(errno.EPERM, os.strerror(errno.EPERM), "fixture")
        return real_popen(*arguments, **options)

    with patch.object(resource_runner.subprocess, "Popen", side_effect=fail_twice):
        status, _, _, _, _ = resource_runner.run_command(
            [sys.executable, "-c", "pass"],
            timeout=5,
            sample_runtime=None,
            sample_container=None,
            sample_interval=1,
        )
    check(status == 0, f"command failed after transient EPERM: status {status}")
    check(len(attempts) == 3, f"expected two EPERM retries, got {len(attempts)} spawn attempts")
    check(
        all(options.get("start_new_session") is True for options in attempts),
        "EPERM retry weakened process-session isolation",
    )

    attempts.clear()

    def fail_persistently(*_arguments: object, **_options: object) -> subprocess.Popen[bytes]:
        attempts.append({})
        raise PermissionError(errno.EPERM, os.strerror(errno.EPERM), "fixture")

    with patch.object(resource_runner.subprocess, "Popen", side_effect=fail_persistently):
        try:
            resource_runner.run_command(
                ["fixture"],
                timeout=5,
                sample_runtime=None,
                sample_container=None,
                sample_interval=1,
            )
        except OSError as error:
            check(error.errno == errno.EPERM, f"persistent EPERM changed: {error}")
        else:
            raise AssertionError("persistent EPERM was swallowed")
    check(len(attempts) == 3, f"persistent EPERM exceeded the three-attempt limit: {len(attempts)}")

    for error_number in (errno.ENOENT, errno.EACCES):
        attempts.clear()

        def fail_exec(*_arguments: object, **_options: object) -> subprocess.Popen[bytes]:
            attempts.append({})
            raise OSError(error_number, os.strerror(error_number), "fixture")

        with patch.object(resource_runner.subprocess, "Popen", side_effect=fail_exec):
            try:
                resource_runner.run_command(
                    ["fixture"],
                    timeout=5,
                    sample_runtime=None,
                    sample_container=None,
                    sample_interval=1,
                )
            except OSError as error:
                check(error.errno == error_number, f"spawn error changed: expected {error_number}, got {error.errno}")
            else:
                raise AssertionError(f"spawn error {error_number} was swallowed")
        check(len(attempts) == 1, f"spawn error {error_number} was retried")


def test_container_memory_is_recorded_when_the_runtime_reports_it() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        runtime = root / "runtime"
        runtime.write_text("#!/bin/sh\nprintf '2.5MiB / 64MiB\\n'\n", encoding="utf-8")
        runtime.chmod(0o755)
        metadata = root / "run.tsv"
        process = start_resource_run(
            slot_dir=root / "slots",
            max_concurrent=1,
            command=[sys.executable, "-c", "import time; time.sleep(1.5)"],
            metadata=metadata,
            sample_runtime=runtime,
            memory_sample_interval="0.2",
        )
        finish(process)
        recorded = metadata.read_text()
        check("command_peak_memory_bytes=2621440" in recorded, "container peak memory was not recorded")
        values = dict(line.split("=", 1) for line in recorded.splitlines())
        check(int(values["command_memory_sample_count"]) >= 3, f"memory samples were not counted: {recorded}")
        check(int(values["command_memory_sample_attempts"]) >= 3, f"memory sampling did not repeat during a command: {recorded}")


def make_fake_swift(directory: Path) -> Path:
    directory.mkdir()
    executable = directory / "swift"
    executable.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$*\" >> \"$FAKE_SWIFT_CALLS\"\n"
        "case \"$1\" in\n"
        "  build) printf 'build output\\n'; exit \"${FAKE_SWIFT_BUILD_STATUS:-0}\" ;;\n"
        "  test) printf '%s\\n' \"${FAKE_SWIFT_TEST_OUTPUT:-test output}\"; exit \"${FAKE_SWIFT_TEST_STATUS:-0}\" ;;\n"
        "esac\n"
        "exit 90\n",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable


def run_focused(
    *,
    fake_bin: Path,
    calls: Path,
    metadata: Path,
    environment: dict[str, str],
    filter_value: str = "SelectedTests",
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(environment)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["FAKE_SWIFT_CALLS"] = str(calls)
    env["SWIFT_BUILD_FLAGS"] = "-Xswiftc -warnings-as-errors"
    command = [
        sys.executable,
        str(FOCUSED_RUNNER),
        "--filter",
        filter_value,
        "--traits",
        "FeatureFlag",
        "--repetitions",
        "3",
        "--jobs",
        "2",
        "--scratch-path",
        str(metadata.parent / "scratch with spaces"),
        "--metadata",
        str(metadata),
    ]
    return subprocess.run(command, text=True, capture_output=True, env=env, check=False)


def test_focused_runner_preserves_flags_and_fails_unmatched_filters() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        fake_bin = root / "bin"
        make_fake_swift(fake_bin)
        calls = root / "swift-calls"
        metadata = root / "run.tsv"
        successful = run_focused(
            fake_bin=fake_bin,
            calls=calls,
            metadata=metadata,
            environment={},
        )
        check(successful.returncode == 0, f"focused runner failed: {successful.stdout}\n{successful.stderr}")
        commands = calls.read_text().splitlines()
        check(len(commands) == 2, f"expected build and test commands, got {commands}")
        check("-warnings-as-errors" in commands[0] and "--build-tests" in commands[0], "strict build flags were dropped")
        check("--jobs 2" in commands[0] and "--scratch-path" in commands[0], "configured build resources were dropped")
        check("--maximum-repetitions 3" in commands[1] and "--filter SelectedTests" in commands[1], "test selection was dropped")
        check("compile_seconds=" in metadata.read_text() and "test_seconds=" in metadata.read_text(), "phase timing metadata is missing")

        unmatched = run_focused(
            fake_bin=fake_bin,
            calls=root / "unmatched-calls",
            metadata=root / "unmatched.tsv",
            environment={"FAKE_SWIFT_TEST_OUTPUT": "warning: No matching test cases were run"},
        )
        check(unmatched.returncode == 1, "a filter with no matching tests did not fail")
        check("matched no tests" in unmatched.stderr, "unmatched filter diagnostic is missing")

        build_failure = run_focused(
            fake_bin=fake_bin,
            calls=root / "build-failure-calls",
            metadata=root / "build-failure.tsv",
            environment={"FAKE_SWIFT_BUILD_STATUS": "41"},
        )
        check(build_failure.returncode == 41, "compiler exit status was not preserved")
        check(len((root / "build-failure-calls").read_text().splitlines()) == 1, "tests ran after a failed compile")

        test_failure = run_focused(
            fake_bin=fake_bin,
            calls=root / "test-failure-calls",
            metadata=root / "test-failure.tsv",
            environment={"FAKE_SWIFT_TEST_STATUS": "29"},
        )
        check(test_failure.returncode == 29, "test failure exit status was not preserved")


def main() -> None:
    tests = [
        test_resource_locks_serialize_only_the_shared_resource,
        test_same_resource_lock_blocks_the_second_writer,
        test_slot_cap_and_timeout_and_exit_status,
        test_cancellation_stops_the_child_and_records_status,
        test_command_spawn_retries_eperm_without_retrying_exec_errors,
        test_container_memory_is_recorded_when_the_runtime_reports_it,
        test_focused_runner_preserves_flags_and_fails_unmatched_filters,
    ]
    for test in tests:
        test()
        print(f"ok: {test.__name__}")
    print(f"agent test tooling checks passed ({len(tests)} tests)")


if __name__ == "__main__":
    main()
