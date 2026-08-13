import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

/// Policy for vacuuming memories during archival
public enum MemoryVacuumPolicy: Sendable {
    /// Do not run vacuuming.
    case skip
    /// Run vacuuming with the specified threshold.
    case run(threshold: Double)
}

/// Service to archive conversations and index them for semantic recall
public actor ThreadArchiver {
    private let persistence: any ThreadPersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol
    private let llmService: any LLMUtilityClient
    private let embeddingService: any EmbeddingServiceProtocol
    private let logger = Logger.module(named: "timeline-archiver")

    public init(
        persistence: any ThreadPersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol,
        llmService: any LLMUtilityClient,
        embeddingService: any EmbeddingServiceProtocol
    ) {
        self.persistence = persistence
        self.llmService = llmService
        self.embeddingService = embeddingService
    }

    /// Deprecated v3 initializer. Legacy timeline persistence is adapted at the boundary.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        persistence: any TimelinePersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol,
        llmService: any LLMUtilityClient,
        embeddingService: any EmbeddingServiceProtocol
    ) {
        self.init(
            persistence: LegacyThreadArchiverPersistence(persistence),
            llmService: llmService,
            embeddingService: embeddingService
        )
    }

    /// Archive a conversation and index its messages as semantic memories
    @discardableResult
    public func archive(
        messages: [Message],
        threadID: UUID?,
        vacuumPolicy: MemoryVacuumPolicy = .run(threshold: 0.95)
    ) async throws -> UUID {
        let title = await resolveTitle(from: messages)
        let archiveState = try await resolveTimeline(threadID: threadID, title: title)

        do {
            try await indexAndSaveMessages(
                messages,
                timeline: archiveState.archivedTimeline,
                title: title
            )

            if case let .run(threshold) = vacuumPolicy {
                _ = try await persistence.vacuumMemories(threshold: threshold)
            }
        } catch {
            await rollback(archiveState, after: error)
            throw error
        }

        return archiveState.archivedTimeline.id
    }

    /// Deprecated v3 parameter label.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @discardableResult
    public func archive(
        messages: [Message],
        timelineId: UUID?,
        vacuumPolicy: MemoryVacuumPolicy = .run(threshold: 0.95)
    ) async throws -> UUID {
        try await archive(messages: messages, threadID: timelineId, vacuumPolicy: vacuumPolicy)
    }

    // MARK: - Helpers

    private func resolveTitle(from messages: [Message]) async -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user })?.content else {
            return "Archived Conversation"
        }
        do {
            let title = try await llmService.generateTitle(for: messages)
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        } catch {
            logger.error("Failed to generate descriptive title: \(ErrorKit.userFriendlyMessage(for: error))")
        }
        return String(firstUserMessage.prefix(40))
    }

    private struct ArchiveState {
        let archivedTimeline: Thread
        let previousTimeline: Thread?
    }

    private func resolveTimeline(threadID: UUID?, title: String) async throws -> ArchiveState {
        if let sid = threadID, let existing = try await persistence.fetchThread(id: sid) {
            var updated = existing
            updated.title = title
            updated.isArchived = true
            updated.updatedAt = Date()
            try await persistence.saveThread(updated)
            return ArchiveState(archivedTimeline: updated, previousTimeline: existing)
        } else {
            var newTimeline = Thread(title: title)
            newTimeline.isArchived = true
            try await persistence.saveThread(newTimeline)
            return ArchiveState(archivedTimeline: newTimeline, previousTimeline: nil)
        }
    }

    private func rollback(_ state: ArchiveState, after originalError: Error) async {
        do {
            if let previousTimeline = state.previousTimeline {
                try await persistence.saveThread(previousTimeline)
            } else {
                try await persistence.deleteThread(id: state.archivedTimeline.id)
            }
        } catch {
            let operation = state.previousTimeline == nil ? "deleteTimeline" : "restoreTimeline"
            logger.error("""
            Archive rollback failed — timeline: \(state.archivedTimeline.id.uuidString.prefix(8)), \
            operation: \(operation), original error: \(ErrorKit.userFriendlyMessage(for: originalError)), \
            cleanup error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
        }
    }

    private func indexAndSaveMessages(
        _ messages: [Message], timeline: Thread, title: String
    ) async throws {
        for msg in messages {
            if msg.content.count > 20 {
                await indexMessageAsMemory(msg, title: title)
            }

            let conversationMsg = ConversationMessage(
                threadID: timeline.id,
                role: .init(rawValue: msg.role.rawValue) ?? .user,
                content: msg.content,
                timestamp: msg.timestamp,
                recalledMemories: "[]",
                parentID: msg.parentID,
                reasoning: msg.reasoning,
                toolCalls: encodeToolCalls(msg.toolCalls)
            )
            try await persistence.saveMessage(conversationMsg)
        }
    }

    private func indexMessageAsMemory(_ msg: Message, title: String) async {
        do {
            let tags = try await llmService.generateTags(for: msg.content)
            let embedding = try await embeddingService.generateEmbedding(for: msg.content)

            let memory = Memory(
                title: title,
                content: msg.content,
                tags: tags,
                embedding: embedding.map { Double($0) }
            )
            _ = try await persistence.saveMemory(memory, policy: .deduplicating(threshold: 0.92))
        } catch {
            logger.error("Failed to index message as memory: \(error.localizedDescription)")
        }
    }

    private func encodeToolCalls(_ toolCalls: [ToolCall]?) -> String {
        guard let calls = toolCalls, let data = try? JSONEncoder().encode(calls) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
