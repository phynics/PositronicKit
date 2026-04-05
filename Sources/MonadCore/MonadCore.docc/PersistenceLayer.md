import MonadShared
# Persistence Layer

Modular storage architecture for MonadCore.

## Domain-Specific Protocols

The persistence layer is split into focused protocols to ensure high cohesion and low coupling:

- `MemoryStoreProtocol`: Vector and semantic memory storage.
- `MessageStoreProtocol`: Chat history management.
- `TimelinePersistenceProtocol`: Conversation timeline lifecycle.
- `AgentTemplateStoreProtocol`: Static agent definitions.
- `WorkspacePersistenceProtocol`: Virtual document workspace tracking.
- `ClientStoreProtocol`: Remote client identity and state.
- `ToolPersistenceProtocol`: Tool registry and routing metadata.

## Implementation

The standard implementation uses **GRDB.swift** with SQLite for robust, thread-safe persistence.

### Composition

While individual protocols are used for specific services, the `FullPersistenceService` typealias can be used when a component requires complete access to the database.
