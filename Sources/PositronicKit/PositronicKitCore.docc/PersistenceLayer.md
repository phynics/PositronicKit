import PKShared
# Persistence Layer

Modular storage architecture for PositronicKitCore.

## Domain-Specific Protocols

The persistence layer is split into focused protocols to ensure high cohesion and low coupling:

- `MemoryStoreProtocol`: Vector and semantic memory storage.
- `MessageStoreProtocol`: Chat history management.
- `TimelinePersistenceProtocol`: Conversation timeline lifecycle.
- `AgentTemplateStoreProtocol`: Static agent definitions.
- `WorkspacePersistenceProtocol`: Virtual document workspace tracking.
- `RequestOriginStoreProtocol`: Request-origin identity and attached-tool metadata.
- `ToolPersistenceProtocol`: Tool registry and routing metadata.

## Implementation

The standard implementation uses **GRDB.swift** with SQLite for robust, thread-safe persistence.

### Composition

Live runtime code depends on focused store protocols directly. `PositronicKitCore.PersistenceConfiguration` groups the commonly required stores for initialization, but runtime services should continue to depend on narrow protocols rather than a monolithic persistence facade.
