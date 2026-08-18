import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

private actor ArchiveFaultInjectingPersistence:
    ThreadPersistenceProtocol, MemoryStoreProtocol, ThreadMessageStoreProtocol
{
    private var threads: [Thread] = []
    private var messages: [ConversationMessage] = []
    private var failMessageSave = false

    func setMessageSaveFailure(_ value: Bool) {
        failMessageSave = value
    }

    func savedThreads() -> [Thread] {
        threads
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

    func fetchMessages(for threadID: UUID) async throws -> [ConversationMessage] {
        messages.filter { $0.threadID == threadID }
    }

    func deleteMessages(for threadID: UUID) async throws {
        messages.removeAll { $0.threadID == threadID }
    }

    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    func fetchSnapshots(for _: UUID) async throws -> [TurnSnapshot] {
        []
    }

    func saveThread(_ thread: Thread) async throws {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
    }

    func fetchThread(id: UUID) async throws -> Thread? {
        threads.first { $0.id == id }
    }

    func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        includeArchived ? threads : threads.filter { !$0.isArchived }
    }

    func deleteThread(id: UUID) async throws {
        threads.removeAll { $0.id == id }
    }

    func pruneThreads(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }
}

@Suite(.serialized)
@MainActor
struct ThreadArchiverTests {
    let persistence: MockPersistenceService
    let mockLLM: MockLLMService
    let archiver: ThreadArchiver
    let mockEmbeddingService: MockEmbeddingService

    init() async throws {
        persistence = MockPersistenceService()
        mockLLM = MockLLMService()
        mockEmbeddingService = MockEmbeddingService()

        archiver = ThreadArchiver(persistence: persistence, llmService: mockLLM, embeddingService: mockEmbeddingService)
    }

    @Test
    func archive_generatesTitleFromSharedUtility() async throws {
        // Given
        mockLLM.mockClient.nextResponse = #"{"title":"A Great Conversation"}"#
        let messages = [
            Message(content: "Hello, I want to talk about Swift programming.", role: .user),
            Message(content: "Let's compare that with SwiftUI data flow.", role: .assistant),
        ]

        // When
        let threadID = try await archiver.archive(messages: messages, threadID: .none)

        // Then
        let session = try await persistence.fetchThread(id: threadID)
        #expect(session?.title == "A Great Conversation")
        #expect(session?.isArchived == true)
    }

    @Test
    func archive_usesDefaultTitleIfNoUserMessage() async throws {
        // Given
        let messages = [
            Message(content: "I am an assistant.", role: .assistant),
        ]

        // When
        let threadID = try await archiver.archive(messages: messages, threadID: .none)

        // Then
        let session = try await persistence.fetchThread(id: threadID)
        #expect(session?.title == "Archived Conversation")
    }

    @Test
    func archive_indexesLongMessagesAsMemories() async throws {
        // Given
        mockLLM.mockClient.nextResponse = #"{"title":"Swift Title"}"#
        mockEmbeddingService.mockEmbedding = [0.1, 0.2, 0.3]

        let longMessage = "This is a very long message that should be indexed as a memory because it is longer than 20 characters."
        let messages = [
            Message(content: longMessage, role: .user),
        ]

        // When
        _ = try await archiver.archive(messages: messages, threadID: .none)

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
        _ = try await archiver.archive(messages: messages, threadID: .none)

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
        let threadID = try await archiver.archive(messages: messages, threadID: .none)

        // Then
        let storedMessages = try await persistence.fetchMessages(for: threadID)
        #expect(storedMessages.count == 2)
        #expect(storedMessages[0].content == "Message 1")
        #expect(storedMessages[1].content == "Message 2")
        #expect(storedMessages[0].threadID == threadID)
        #expect(storedMessages[1].threadID == threadID)
    }

    @Test
    func archive_updatesExistingSession() async throws {
        // Given
        let existingSession = Thread(title: "Old Title")
        try await persistence.saveThread(existingSession)

        mockLLM.mockClient.nextResponse = #"{"title":"New Title"}"#
        let messages = [
            Message(content: "New user message", role: .user),
        ]

        // When
        let threadID = try await archiver.archive(messages: messages, threadID: existingSession.id)

        // Then
        #expect(threadID == existingSession.id)
        let updatedSession = try await persistence.fetchThread(id: existingSession.id)
        #expect(updatedSession?.title == "New Title")
        #expect(updatedSession?.isArchived == true)
    }

    @Test
    func archive_fallsBackToFirstUserMessageWhenTitleGenerationFails() async throws {
        // Given — strict title generation fails, so the archiver's own fallback applies.
        mockLLM.mockClient.shouldThrowError = true
        let firstUserMessage = "This is the first user message that should become the title."
        let messages = [
            Message(content: firstUserMessage, role: .user),
        ]

        // When
        let threadID = try await archiver.archive(messages: messages, threadID: .none)

        // Then
        let session = try await persistence.fetchThread(id: threadID)
        #expect(session?.title == String(firstUserMessage.prefix(40)))
    }

    @Test
    func archiveRollsBackThreadStateWhenMessageSaveFails() async throws {
        let createPersistence = ArchiveFaultInjectingPersistence()
        await createPersistence.setMessageSaveFailure(true)
        let createArchiver = ThreadArchiver(
            persistence: createPersistence,
            llmService: MockLLMService(),
            embeddingService: MockEmbeddingService()
        )

        var createDidThrowExpectedError = false
        do {
            _ = try await createArchiver.archive(
                messages: [Message(content: "archive failure", role: .assistant)],
                threadID: nil,
                vacuumPolicy: .skip
            )
        } catch FailingStoreError.saveFailed {
            createDidThrowExpectedError = true
        } catch {
            Issue.record("Unexpected create error: \(error)")
        }

        #expect(createDidThrowExpectedError)
        let createdThreads = await createPersistence.savedThreads()
        #expect(createdThreads.isEmpty)

        let updatePersistence = ArchiveFaultInjectingPersistence()
        let originalThread = Thread(
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
        try await updatePersistence.saveThread(originalThread)
        await updatePersistence.setMessageSaveFailure(true)
        let updateArchiver = ThreadArchiver(
            persistence: updatePersistence,
            llmService: MockLLMService(),
            embeddingService: MockEmbeddingService()
        )

        var updateDidThrowExpectedError = false
        do {
            _ = try await updateArchiver.archive(
                messages: [Message(content: "archive failure", role: .assistant)],
                threadID: originalThread.id,
                vacuumPolicy: .skip
            )
        } catch FailingStoreError.saveFailed {
            updateDidThrowExpectedError = true
        } catch {
            Issue.record("Unexpected update error: \(error)")
        }

        #expect(updateDidThrowExpectedError)
        let restoredThread = try #require(await updatePersistence.fetchThread(id: originalThread.id))
        #expect(restoredThread.id == originalThread.id)
        #expect(restoredThread.title == originalThread.title)
        #expect(restoredThread.createdAt == originalThread.createdAt)
        #expect(restoredThread.updatedAt == originalThread.updatedAt)
        #expect(restoredThread.isArchived == originalThread.isArchived)
        #expect(restoredThread.workingDirectory == originalThread.workingDirectory)
        #expect(restoredThread.attachedWorkspaceIDs == originalThread.attachedWorkspaceIDs)
        #expect(restoredThread.attachedAgentInstanceID == originalThread.attachedAgentInstanceID)
        #expect(restoredThread.isPrivate == originalThread.isPrivate)
    }

    @Test
    func archive_handlesEmptyMessages() async throws {
        // When
        let threadID = try await archiver.archive(messages: [], threadID: .none)

        // Then
        let session = try await persistence.fetchThread(id: threadID)
        #expect(session?.title == "Archived Conversation")

        let storedMessages = try await persistence.fetchMessages(for: threadID)
        #expect(storedMessages.isEmpty)
    }
}
