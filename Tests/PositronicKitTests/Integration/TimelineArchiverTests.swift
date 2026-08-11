import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

private actor ArchiveFaultInjectingPersistence:
    TimelinePersistenceProtocol, MemoryStoreProtocol, MessageStoreProtocol
{
    private var timelines: [Timeline] = []
    private var messages: [ConversationMessage] = []
    private var failMessageSave = false

    func setMessageSaveFailure(_ value: Bool) {
        failMessageSave = value
    }

    func savedTimelines() -> [Timeline] {
        timelines
    }

    func saveMemory(_ memory: Memory, policy _: MemorySavePolicy) async throws -> UUID {
        memory.id
    }

    func fetchMemory(id _: UUID) async throws -> Memory? {
        nil
    }

    func fetchAllMemories() async throws -> [Memory] {
        []
    }

    func searchMemories(query _: String) async throws -> [Memory] {
        []
    }

    func searchMemories(
        embedding _: [Double], limit _: Int, minSimilarity _: Double
    ) async throws -> [(memory: Memory, similarity: Double)] {
        []
    }

    func searchMemories(matchingAnyTag _: [String]) async throws -> [Memory] {
        []
    }

    func deleteMemory(id _: UUID) async throws {}
    func updateMemory(_: Memory) async throws {}
    func updateMemoryEmbedding(id _: UUID, newEmbedding _: [Double]) async throws {}
    func vacuumMemories(threshold _: Double) async throws -> Int { 0 }
    func pruneMemories(matching _: String, dryRun _: Bool) async throws -> Int { 0 }
    func pruneMemories(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    func saveMessage(_ message: ConversationMessage) async throws {
        if failMessageSave {
            throw FailingStoreError.saveFailed
        }
        messages.append(message)
    }

    func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        messages.filter { $0.timelineID == timelineId }
    }

    func deleteMessages(for timelineId: UUID) async throws {
        messages.removeAll { $0.timelineID == timelineId }
    }

    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    func fetchSnapshots(for _: UUID) async throws -> [TurnSnapshot] {
        []
    }

    func saveTimeline(_ timeline: Timeline) async throws {
        if let index = timelines.firstIndex(where: { $0.id == timeline.id }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
    }

    func fetchTimeline(id: UUID) async throws -> Timeline? {
        timelines.first { $0.id == id }
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        includeArchived ? timelines : timelines.filter { !$0.isArchived }
    }

    func deleteTimeline(id: UUID) async throws {
        timelines.removeAll { $0.id == id }
    }

    func pruneTimelines(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }
}

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
    func archive_generatesTitleFromSharedUtility() async throws {
        // Given
        mockLLM.nextGeneratedTitle = "A Great Conversation"
        let messages = [
            Message(content: "Hello, I want to talk about Swift programming.", role: .user),
            Message(content: "Let's compare that with SwiftUI data flow.", role: .assistant),
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let session = try await persistence.fetchTimeline(id: timelineId)
        #expect(session?.title == "A Great Conversation")
        #expect(session?.isArchived == true)
        #expect(mockLLM.generatedTitleInputs.count == 1)
        #expect(mockLLM.generatedTitleInputs.first == messages)
    }

    @Test
    func archive_usesDefaultTitleIfNoUserMessage() async throws {
        // Given
        let messages = [
            Message(content: "I am an assistant.", role: .assistant),
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
        mockLLM.nextGeneratedTitle = "Swift Title"
        mockEmbeddingService.mockEmbedding = [0.1, 0.2, 0.3]

        let longMessage = "This is a very long message that should be indexed as a memory because it is longer than 20 characters."
        let messages = [
            Message(content: longMessage, role: .user),
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
            Message(content: shortMessage, role: .user),
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
            Message(content: "Message 2", role: .assistant),
        ]

        // When
        let timelineId = try await archiver.archive(messages: messages, timelineId: .none)

        // Then
        let storedMessages = try await persistence.fetchMessages(for: timelineId)
        #expect(storedMessages.count == 2)
        #expect(storedMessages[0].content == "Message 1")
        #expect(storedMessages[1].content == "Message 2")
        #expect(storedMessages[0].timelineID == timelineId)
        #expect(storedMessages[1].timelineID == timelineId)
    }

    @Test
    func archive_updatesExistingSession() async throws {
        // Given
        let existingSession = Timeline(title: "Old Title")
        try await persistence.saveTimeline(existingSession)

        mockLLM.nextGeneratedTitle = "New Title"
        let messages = [
            Message(content: "New user message", role: .user),
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
    func archiveRollsBackTimelineStateWhenMessageSaveFails() async throws {
        let createPersistence = ArchiveFaultInjectingPersistence()
        await createPersistence.setMessageSaveFailure(true)
        let createArchiver = TimelineArchiver(
            persistence: createPersistence,
            llmService: MockLLMService(),
            embeddingService: MockEmbeddingService()
        )

        var createDidThrowExpectedError = false
        do {
            _ = try await createArchiver.archive(
                messages: [Message(content: "archive failure", role: .assistant)],
                timelineId: nil,
                vacuumPolicy: .skip
            )
        } catch FailingStoreError.saveFailed {
            createDidThrowExpectedError = true
        } catch {
            Issue.record("Unexpected create error: \(error)")
        }

        #expect(createDidThrowExpectedError)
        let createdTimelines = await createPersistence.savedTimelines()
        #expect(createdTimelines.isEmpty)

        let updatePersistence = ArchiveFaultInjectingPersistence()
        let originalTimeline = Timeline(
            id: UUID(),
            title: "Original title",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            isArchived: false,
            workingDirectory: "/tmp/archive",
            attachedWorkspaceIDs: [UUID()],
            attachedAgentInstanceID: UUID(),
            isPrivate: true
        )
        try await updatePersistence.saveTimeline(originalTimeline)
        await updatePersistence.setMessageSaveFailure(true)
        let updateArchiver = TimelineArchiver(
            persistence: updatePersistence,
            llmService: MockLLMService(),
            embeddingService: MockEmbeddingService()
        )

        var updateDidThrowExpectedError = false
        do {
            _ = try await updateArchiver.archive(
                messages: [Message(content: "archive failure", role: .assistant)],
                timelineId: originalTimeline.id,
                vacuumPolicy: .skip
            )
        } catch FailingStoreError.saveFailed {
            updateDidThrowExpectedError = true
        } catch {
            Issue.record("Unexpected update error: \(error)")
        }

        #expect(updateDidThrowExpectedError)
        let restoredTimeline = try #require(await updatePersistence.fetchTimeline(id: originalTimeline.id))
        #expect(restoredTimeline.id == originalTimeline.id)
        #expect(restoredTimeline.title == originalTimeline.title)
        #expect(restoredTimeline.createdAt == originalTimeline.createdAt)
        #expect(restoredTimeline.updatedAt == originalTimeline.updatedAt)
        #expect(restoredTimeline.isArchived == originalTimeline.isArchived)
        #expect(restoredTimeline.workingDirectory == originalTimeline.workingDirectory)
        #expect(restoredTimeline.attachedWorkspaceIDs == originalTimeline.attachedWorkspaceIDs)
        #expect(restoredTimeline.attachedAgentInstanceID == originalTimeline.attachedAgentInstanceID)
        #expect(restoredTimeline.isPrivate == originalTimeline.isPrivate)
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
