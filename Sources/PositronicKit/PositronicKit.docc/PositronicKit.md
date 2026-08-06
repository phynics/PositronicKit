# ``PositronicKit``

The transport-neutral runtime facade for PositronicKit.

## Overview

PositronicKit provides the public runtime entry point for timeline management, prompt assembly, context gathering, tool execution, and persistence. It assembles runtime dependencies internally from explicit initializer parameters so downstream applications integrate through normal Swift initializers instead of configuring a dependency container directly.

### Key Components

- **PositronicKit facade**: The public entry point; `run(_ request:)` drives a chat turn end to end.
- **TimelineManager**: Coordinates timeline lifecycle, context gathering, and workspace attachment.
- **Persistence Layer**: A suite of domain-specific store protocols.
- **Tool System**: Runtime-managed and host-attached tool routing (`ToolRouter`) over shared tool contracts.

### Language Model Readiness

Await ``PositronicKit/isLanguageModelConfigured`` to determine whether the injected language
model currently has usable provider configuration. The value is read live from the model;
the facade does not expose provider details, credentials, or configuration mutation.

### Logging And Errors

- Runtime diagnostics use `swift-log`.
- Hosts own logging bootstrap and log-level configuration.
- Prompt assembly diagnostics are enabled per turn with `PositronicKit.run(_:)` via `ChatRunRequest.promptAssemblyLogger`.
- Package-defined errors conform to `PKError` and surface user-facing messages through `ErrorKit`.

## Topics

### Architecture

- <doc:ArchitectureOverview>
- <doc:PersistenceLayer>

### Runtime Surfaces

Use the module articles above for architecture and persistence guidance. Shared tool contracts and message models live in `PKShared`, while prompt construction APIs live in `PKPrompt`.
