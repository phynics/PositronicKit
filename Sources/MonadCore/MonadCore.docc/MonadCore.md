import MonadShared
# ``MonadCore``

The foundational logic and state management framework for Monad AI Assistant.

## Overview

MonadCore provides the core engine for timeline management, context gathering, tool execution, and persistence. It is designed to be highly modular and decoupled, enabling easy testing and integration with various LLM providers.

### Key Components

- **ChatEngine**: Orchestrates the interaction between users, agent templates, and LLMs.
- **ContextManager**: Handles semantic retrieval and context window optimization.
- **Persistence Layer**: A suite of domain-specific protocols for SQLite/GRDB storage.
- **Tool System**: Type-safe DSL for defining and executing AI tools.

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
