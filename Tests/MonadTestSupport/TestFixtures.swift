import Foundation
import MonadCore
import MonadShared

#if DEBUG
    public extension Message {
        static func fixture(
            id: UUID = UUID(),
            role: MessageRole = .user,
            content: String = "Test message content",
            timestamp: Date = Date()
        ) -> Message {
            Message(id: id, timestamp: timestamp, content: content, role: role)
        }
    }

    public extension Memory {
        static func fixture(
            id: UUID = UUID(),
            title: String = "Test Memory",
            content: String = "Test memory content",
            tags: [String] = ["test"],
            timestamp: Date = Date()
        ) -> Memory {
            Memory(id: id, title: title, content: content, createdAt: timestamp, updatedAt: timestamp, tags: tags)
        }
    }

    public extension WorkspaceReference {
        static func fixture(
            id: UUID = UUID(),
            uri: WorkspaceURI = .serverTimeline(UUID()),
            hostType: WorkspaceHostType = .server,
            ownerId: UUID? = nil,
            rootPath: String? = nil,
            tools: [ToolReference] = [],
            status: WorkspaceStatus = .active
        ) -> WorkspaceReference {
            WorkspaceReference(
                id: id,
                uri: uri,
                hostType: hostType,
                ownerId: ownerId,
                tools: tools,
                rootPath: rootPath,
                trustLevel: .full,
                status: status
            )
        }
    }
#endif
