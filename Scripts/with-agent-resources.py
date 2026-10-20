#!/usr/bin/env python3
"""Run one command under resource-scoped locks and a host-wide concurrency cap."""

from __future__ import annotations

import argparse
import errno
import fcntl
import math
import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def append_metadata(path: str | None, values: list[tuple[str, str]]) -> None:
    if path is None:
        return
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        payload = "".join(f"{key}={value}\n" for key, value in values).encode()
        os.write(descriptor, payload)
    finally:
        os.close(descriptor)


def open_lock(path: str) -> int:
    lock_path = Path(path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    os.fchmod(descriptor, 0o600)
    return descriptor


def acquire_lock(descriptor: int, deadline: float, description: str) -> None:
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for {description}")
            time.sleep(min(0.05, remaining))


def acquire_slot(slot_dir: str, count: int, deadline: float) -> tuple[int, int]:
    directory = Path(slot_dir)
    directory.mkdir(parents=True, exist_ok=True)
    while True:
        for slot in range(1, count + 1):
            descriptor = open_lock(str(directory / f"slot-{slot}.lock"))
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return descriptor, slot
            except BlockingIOError:
                os.close(descriptor)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for one of {count} agent run slots")
        time.sleep(min(0.05, remaining))


def stop_process(process: subprocess.Popen[bytes], signum: int, *, process_group: bool) -> None:
    try:
        if process_group:
            os.killpg(process.pid, signum)
        else:
            process.send_signal(signum)
    except ProcessLookupError:
        pass


def start_process(command: list[str]) -> tuple[subprocess.Popen[bytes], bool]:
    """Start a command in its own session, degrading on persistent EPERM.

    macOS intermittently denies session creation with EPERM. Retry briefly, then
    start without a new session so the gate reports the command result instead
    of failing on the spawn itself.
    """
    for attempt in range(3):
        try:
            return subprocess.Popen(command, start_new_session=True), True
        except OSError as error:
            if error.errno != errno.EPERM:
                raise
            if attempt == 2:
                break
            time.sleep(0.05 * (attempt + 1))
    print(
        "with-agent-resources: session creation denied; continuing without a new process session",
        file=sys.stderr,
    )
    return subprocess.Popen(command, start_new_session=False), False


def parse_memory_bytes(value: str) -> int | None:
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*(B|KB|KiB|MB|MiB|GB|GiB|TB|TiB)", value, re.I)
    if match is None:
        return None
    amount = float(match.group(1))
    unit = match.group(2).lower()
    factor = {
        "b": 1,
        "kb": 1000,
        "kib": 1024,
        "mb": 1000**2,
        "mib": 1024**2,
        "gb": 1000**3,
        "gib": 1024**3,
        "tb": 1000**4,
        "tib": 1024**4,
    }[unit]
    return int(amount * factor)


class MemorySampler:
    """Read a runtime's streaming stats without blocking the test command."""

    def __init__(self, runtime: str, container: str) -> None:
        self.process = subprocess.Popen(
            [runtime, "stats", "--format", "{{.MemUsage}}", container],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            bufsize=0,
        )
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.stdout_fd = self.process.stdout.fileno()
        os.set_blocking(self.stdout_fd, False)
        self.pending = b""
        self.samples: list[int] = []
        self.error = ""

    def poll(self, *, report_exit_error: bool = True) -> bool:
        """Collect currently available samples; return true after the process exits."""
        assert self.process.stdout is not None
        readable, _, _ = select.select([self.stdout_fd], [], [], 0)
        while readable:
            try:
                chunk = os.read(self.stdout_fd, 4096)
            except BlockingIOError:
                break
            if not chunk:
                break
            self.pending += chunk
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                self._record(line.decode(errors="replace"))
            readable, _, _ = select.select([self.stdout_fd], [], [], 0)

        status = self.process.poll()
        if status is None:
            return False

        if self.pending:
            self._record(self.pending.decode(errors="replace"))
            self.pending = b""
        if status != 0:
            if report_exit_error:
                assert self.process.stderr is not None
                self.error = self.process.stderr.read().decode(errors="replace").strip().replace("\n", " ")[:240]
                if not self.error:
                    self.error = f"stats exited {status}"
        return True

    def _record(self, value: str) -> None:
        value = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", value).strip()
        if not value:
            return
        usage = parse_memory_bytes(value.split("/", 1)[0].strip())
        if usage is not None and usage > 0:
            self.samples.append(usage)
            self.error = ""
        elif value.strip():
            self.error = f"unrecognized or zero stats output: {value.strip()[:200]}"

    def stop(self) -> None:
        was_running = self.process.poll() is None
        if was_running:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait()
        self.poll(report_exit_error=not was_running)
        if self.process.stdout is not None:
            self.process.stdout.close()
        if self.process.stderr is not None:
            self.process.stderr.close()


def run_command(
    command: list[str],
    timeout: float,
    sample_runtime: str | None,
    sample_container: str | None,
    sample_interval: float,
) -> tuple[int, float, list[int], int, str]:
    started = time.monotonic()
    received_signal: int | None = None

    def record_signal(signum: int, _frame: object) -> None:
        nonlocal received_signal
        received_signal = signum

    old_handlers = {
        signum: signal.signal(signum, record_signal)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    process: subprocess.Popen[bytes] | None = None
    memory_samples: list[int] = []
    memory_attempts = 0
    memory_error = ""
    sampler: MemorySampler | None = None
    reported_sampler_samples = 0

    def collect_memory() -> None:
        nonlocal reported_sampler_samples, memory_error
        if sampler is None:
            return
        memory_samples.extend(sampler.samples[reported_sampler_samples:])
        reported_sampler_samples = len(sampler.samples)
        if sampler.error:
            memory_error = sampler.error

    def poll_memory() -> None:
        nonlocal sampler, memory_attempts, memory_error, next_sample, reported_sampler_samples
        now = time.monotonic()
        if sampler is not None:
            finished = sampler.poll()
            collect_memory()
            if finished:
                sampler = None
                reported_sampler_samples = 0
                next_sample = now + sample_interval
        if sampler is None and sample_runtime and sample_container and now >= next_sample:
            memory_attempts += 1
            try:
                sampler = MemorySampler(sample_runtime, sample_container)
                reported_sampler_samples = 0
            except OSError as error:
                memory_error = f"could not start runtime stats: {error}"
            next_sample = now + sample_interval

    def stop_memory() -> None:
        nonlocal sampler, reported_sampler_samples
        if sampler is not None:
            sampler.stop()
            collect_memory()
            sampler = None
            reported_sampler_samples = 0
    process_group = True
    try:
        process, process_group = start_process(command)
        deadline = started + timeout
        next_sample = started
        while True:
            poll_memory()
            if received_signal is not None:
                stop_process(process, received_signal, process_group=process_group)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    stop_process(process, signal.SIGKILL, process_group=process_group)
                    process.wait()
                stop_memory()
                return 128 + received_signal, time.monotonic() - started, memory_samples, memory_attempts, memory_error

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                target = "process group" if process_group else "command"
                print(f"with-agent-resources: command exceeded {timeout:g}s; stopping {target}", file=sys.stderr)
                stop_process(process, signal.SIGTERM, process_group=process_group)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    stop_process(process, signal.SIGKILL, process_group=process_group)
                    process.wait()
                stop_memory()
                return 124, time.monotonic() - started, memory_samples, memory_attempts, memory_error

            try:
                wait_time = min(remaining, 0.1)
                status = process.wait(timeout=wait_time)
                if status < 0:
                    status = 128 + abs(status)
                stop_memory()
                return status, time.monotonic() - started, memory_samples, memory_attempts, memory_error
            except subprocess.TimeoutExpired:
                continue
    finally:
        stop_memory()
        if process is not None and process.poll() is None:
            stop_process(process, signal.SIGTERM, process_group=process_group)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                stop_process(process, signal.SIGKILL, process_group=process_group)
                process.wait()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource-lock", help="lock only commands sharing this writable resource")
    parser.add_argument("--slot-dir", required=True, help="shared host directory for concurrency slots")
    parser.add_argument("--max-concurrent", type=positive_int, default=3)
    parser.add_argument("--lock-timeout", type=positive_float, default=3600)
    parser.add_argument("--timeout", type=positive_float, required=True, help="command deadline in seconds")
    parser.add_argument("--metadata", help="append timing and exit data to this run metadata file")
    parser.add_argument("--phase", default="command", help="metadata prefix for this command")
    parser.add_argument("--sample-runtime", help="container runtime used for memory telemetry")
    parser.add_argument("--sample-container", help="named container to sample")
    parser.add_argument(
        "--memory-sample-interval",
        type=positive_float,
        default=2.0,
        help="retry delay when container runtime stats exit before the run ends",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if bool(args.sample_runtime) != bool(args.sample_container):
        parser.error("--sample-runtime and --sample-container must be supplied together")

    lock_started = time.monotonic()
    lock_deadline = lock_started + args.lock_timeout
    descriptors: list[int] = []
    slot: int | None = None
    status = 124
    lock_wait_seconds = 0.0
    command_seconds = 0.0
    memory_samples: list[int] = []
    memory_attempts = 0
    memory_error = ""
    try:
        if args.resource_lock:
            resource_descriptor = open_lock(args.resource_lock)
            descriptors.append(resource_descriptor)
            acquire_lock(resource_descriptor, lock_deadline, f"resource lock {args.resource_lock}")
        slot_descriptor, slot = acquire_slot(args.slot_dir, args.max_concurrent, lock_deadline)
        descriptors.append(slot_descriptor)
        lock_wait_seconds = time.monotonic() - lock_started
        print(
            f"with-agent-resources: phase={args.phase} slot={slot}/{args.max_concurrent} "
            f"lock_wait={lock_wait_seconds:.3f}s timeout={args.timeout:g}s"
        )
        status, command_seconds, memory_samples, memory_attempts, memory_error = run_command(
            command,
            args.timeout,
            args.sample_runtime,
            args.sample_container,
            args.memory_sample_interval,
        )
    except TimeoutError as error:
        lock_wait_seconds = time.monotonic() - lock_started
        print(f"with-agent-resources: {error}", file=sys.stderr)
    except OSError as error:
        lock_wait_seconds = time.monotonic() - lock_started
        print(f"with-agent-resources: could not start {command[0]}: {error}", file=sys.stderr)
        status = 127
    finally:
        append_metadata(
            args.metadata,
            [
                (f"{args.phase}_lock_wait_seconds", f"{lock_wait_seconds:.3f}"),
                (f"{args.phase}_command_seconds", f"{command_seconds:.3f}"),
                (f"{args.phase}_exit_status", str(status)),
                (f"{args.phase}_timeout_seconds", f"{args.timeout:g}"),
                (f"{args.phase}_slot", str(slot or "unavailable")),
                (f"{args.phase}_peak_memory_bytes", str(max(memory_samples)) if memory_samples else "unavailable"),
                (f"{args.phase}_memory_sample_count", str(len(memory_samples))),
                (f"{args.phase}_memory_sample_attempts", str(memory_attempts)),
                (f"{args.phase}_memory_error", memory_error if not memory_samples else "none"),
            ],
        )
        for descriptor in reversed(descriptors):
            os.close(descriptor)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
