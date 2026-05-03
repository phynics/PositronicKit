import Foundation
import Logging
import PKShared

/// Policy for vacuuming memories during archival
public enum MemoryVacuumPolicy: Sendable {
    /// Do not run vacuuming.
    case skip
    /// Run vacuuming with the specified threshold.
    case run(threshold: Double)
}

/// Service to archive conversations and index them for semantic recall
public actor TimelineArchiver {
    private let persistence: any TimelinePersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol
    private let llmService: any LLMServiceProtocol
    private let embeddingService: any EmbeddingServiceProtocol
    private let logger = Logger.module(named: "TimelineArchiver")

    public init(
        persistence: any TimelinePersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol,
        llmService: any LLMServiceProtocol,
        embeddingService: any EmbeddingServiceProtocol
    ) {
        self.persistence = persistence
        self.llmService = llmService
        self.embeddingService = embeddingService
    }

    /// Archive a conversation and index its messages as semantic memories
    @discardableResult
    public func archive(
        messages: [Message],
        timelineId: UUID?,
        vacuumPolicy: MemoryVacuumPolicy = .run(threshold: 0.95)
    ) async throws -> UUID {
        let title = await resolveTitle(from: messages)
        let timeline = try await resolveTimeline(timelineId: timelineId, title: title)

        try await indexAndSaveMessages(messages, timeline: timeline, title: title)

        if case let .run(threshold) = vacuumPolicy {
            _ = try await persistence.vacuumMemories(threshold: threshold)
        }

        return timeline.id
    }

    // MARK: - Helpers

    private func resolveTitle(from messages: [Message]) async -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user })?.content else {
            return "Archived Conversation"
        }
        do {
            return try await generateTitle(for: firstUserMessage)
        } catch {
            logger.error("Failed to generate descriptive title: \(error.localizedDescription)")
            return String(firstUserMessage.prefix(40))
        }
    }

    private func resolveTimeline(timelineId: UUID?, title: String) async throws -> Timeline {
        if let sid = timelineId, let existing = try await persistence.fetchTimeline(id: sid) {
            var updated = existing
            updated.title = title
            updated.isArchived = true
            updated.updatedAt = Date()
            try await persistence.saveTimeline(updated)
            return updated
        } else {
            var newTimeline = Timeline(title: title)
            newTimeline.isArchived = true
            try await persistence.saveTimeline(newTimeline)
            return newTimeline
        }
    }

    private func indexAndSaveMessages(
        _ messages: [Message], timeline: Timeline, title: String
    ) async throws {
        for msg in messages {
            if msg.content.count > 20 {
                await indexMessageAsMemory(msg, title: title)
            }

            let conversationMsg = ConversationMessage(
                timelineId: timeline.id,
                role: .init(rawValue: msg.role.rawValue) ?? .user,
                content: msg.content,
                timestamp: msg.timestamp,
                recalledMemories: "[]",
                parentId: msg.parentId,
                think: msg.think,
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
            _ = try await persistence.saveMemory(memory, policy: .preventSimilar(threshold: 0.92))
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

    private func generateTitle(for userMessage: String) async throws -> String {
        let prompt = """
        Generate a very short, descriptive title (max 5 words) for a conversation that starts with:
        \(userMessage)
        Title:
        """

        let response = try await llmService.sendMessage(
            prompt,
            responseFormat: nil as LLMResponseFormat?,
            generationParameters: nil,
            useUtilityModel: true
        )
        return response.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
