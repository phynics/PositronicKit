import PKShared
# ``PositronicKitCore``

The transport-neutral runtime facade for PositronicKit.

## Overview

PositronicKitCore provides the public runtime entry point for timeline management, prompt assembly, context gathering, tool execution, and persistence. It injects runtime dependencies internally so downstream applications integrate through normal Swift initializers instead of configuring the dependency container directly.

### Key Components

- **ChatEngine**: Orchestrates the interaction between users, agent templates, and LLMs.
- **ContextManager**: Handles semantic retrieval and context window optimization.
- **Persistence Layer**: A suite of domain-specific store protocols.
- **Tool System**: Runtime-managed and host-attached tool routing over shared tool contracts.

### Logging And Errors

- Runtime diagnostics use `swift-log`.
- Hosts own logging bootstrap and log-level configuration.
- Prompt assembly diagnostics are enabled with `PromptAssemblyOptions(logger:)`.
- Package-defined errors conform to `PKError` and surface user-facing messages through `ErrorKit`.

## Topics

### Architecture

- <doc:ArchitectureOverview>
- <doc:PersistenceLayer>

### Tool System

- ``Tool``
- ``ToolParameterSchema``
- ``ToolParameters``

### Context & Retrieval

- ``ContextManager``
- ``Memory``
- ``Message``
