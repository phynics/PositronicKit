# Persistence Layer

Modular storage architecture for PositronicKit.

## Domain-Specific Protocols

The persistence layer is split into focused protocols to ensure high cohesion and low coupling:

- `MemoryStoreProtocol`: Vector and semantic memory storage.
- `MessageStoreProtocol`: Chat history management.
- `ThreadPersistenceProtocol`: Conversation thread lifecycle.
- `WorkspaceStore`: Virtual document workspace tracking.
- `RequestOriginStoreProtocol`: Request-origin identity and attached-tool metadata.
- `ToolPersistenceProtocol`: Tool registry and routing metadata.

## Implementation

PositronicKit does not ship a canonical database backend. Hosts provide the storage implementation that fits their environment, whether that is in-memory state, SQLite, cloud storage, or another persistence layer that conforms to the store protocols.

### Composition

Live runtime code depends on focused store protocols directly. `PositronicKit.PersistenceConfiguration` groups the commonly required stores for initialization, but runtime services should continue to depend on narrow protocols rather than a monolithic persistence facade.
