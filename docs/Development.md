# PositronicKit Development Guide

This guide covers contributor and agent setup. Application configuration belongs in
[Setup.md](Setup.md); release procedure belongs in [Releasing.md](Releasing.md).

## Platform gates

Use native Swift/Xcode on macOS. The canonical macOS gate is `make verify`.

Linux verification runs only through the repository-owned Podman runner:

```bash
make doctor
make agent-verify
make agent-test FILTER='MessageContentTests'
```

The runner owns image selection, rootless identity, checkout mounts,
logs, and shared-build locking. Host edits are visible in `/workspace`; build artifacts remain in
the gitignored `.build/` directory. If a sandbox blocks Podman, rerun the same Make target with
container-runtime permission rather than composing a different container command.

## Linux image and prerequisites

The development image supplies Swift 6.3.3 and Python 3 for the documentation catalog gates on Ubuntu 24.04. Build or
refresh it with `make linux-image`; compile in it with `make linux-build`.

## Focused checks

Use `make agent-test FILTER='…'` for a focused Linux test.

## Target boundaries

`PKContracts` owns runtime-neutral provider, tool, structured-output, and diagnostic
contracts. Providers depend on it without importing `PositronicKit`. Runtime dependencies stay
inward: `PKContracts` imports no project target. `make verify-dependency-direction` enforces this
boundary.
