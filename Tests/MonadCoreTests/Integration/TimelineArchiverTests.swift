import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite(.serialized)
@MainActor
struct TimelineArchiverTests {
    let persistence: MockPersistenceService
    let mockLLM: MockLLMService
    let archiver: TimelineArchiver
    let mockEmbeddingService: MockEmbeddingService

    init() async throws {
        persistence = MockPersistenceService()
        mockLLM = MockLLMService()
        mockEmbeddingService = MockEmbeddingService()

        archiver = TimelineArchiver(persistence: persistence, llmService: mockLLM, embeddingService: mockEmbeddingService)
    }

    @Test
    func archive_generatesTitleFromFirstUserMessage() async throws {
        // Given
        mockLLM.nextResponse = "A Great Conversation"
        let messages = [
            Message(content: "Hello, I want to talk about Swift programming.", role: .user)
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let session = try await persistence.fetchTimeline(id: timelineId)
        #expect(session?.title == "A Great Conversation")
        #expect(session?.isArchived == true)
    }

    @Test
    func archive_usesDefaultTitleIfNoUserMessage() async throws {
        // Given
        let messages = [
            Message(content: "I am an assistant.", role: .assistant)
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let session = try await persistence.fetchTimeline(id: timelineId)
        #expect(session?.title == "Archived Conversation")
    }

    @Test
    func archive_indexesLongMessagesAsMemories() async throws {
        // Given
        mockLLM.nextResponse = "Swift Title"
        mockEmbeddingService.mockEmbedding = [0.1, 0.2, 0.3]

        let longMessage = "This is a very long message that should be indexed as a memory because it is longer than 20 characters."
        let messages = [
            Message(content: longMessage, role: .user)
        ]

        // When
        _ = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let memories = try await persistence.fetchAllMemories()
        #expect(memories.count == 1)
        #expect(memories.first?.content == longMessage)
        let vector = memories.first?.embeddingVector ?? []
        #expect(vector.count == 3)
        #expect(abs(vector[0] - 0.1) < 0.001)
    }

    @Test
    func archive_skipsShortMessagesFromIndexing() async throws {
        // Given
        let shortMessage = "Too short."
        let messages = [
            Message(content: shortMessage, role: .user)
        ]

        // When
        _ = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let memories = try await persistence.fetchAllMemories()
        #expect(memories.isEmpty)
    }

    @Test
    func archive_associatesMessagesWithSession() async throws {
        // Given
        let messages = [
            Message(content: "Message 1", role: .user),
            Message(content: "Message 2", role: .assistant)
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let storedMessages = try await persistence.fetchMessages(for: timelineId)
        #expect(storedMessages.count == 2)
        #expect(storedMessages[0].content == "Message 1")
        #expect(storedMessages[1].content == "Message 2")
        #expect(storedMessages[0].timelineId == timelineId)
        #expect(storedMessages[1].timelineId == timelineId)
    }

    @Test
    func archive_updatesExistingSession() async throws {
        // Given
        let existingSession = Timeline(title: "Old Title")
        try await persistence.saveTimeline(existingSession)

        mockLLM.nextResponse = "New Title"
        let messages = [
            Message(content: "New user message", role: .user)
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: existingSession.id)

        // Then
        #expect(timelineId == existingSession.id)
        let updatedSession = try await persistence.fetchTimeline(id: existingSession.id)
        #expect(updatedSession?.title == "New Title")
        #expect(updatedSession?.isArchived == true)
    }

    @Test
    func archive_handlesEmptyMessages() async throws {
        // When
        let timelineId = try await archiver.archive(messages: [], timelineId: .none)

        // Then
        let session = try await persistence.fetchTimeline(id: timelineId)
        #expect(session?.title == "Archived Conversation")

        let storedMessages = try await persistence.fetchMessages(for: timelineId)
        #expect(storedMessages.isEmpty)
    }
}
