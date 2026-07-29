import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-029: workspace creation is an explicit profile with documented filesystem behavior.
///
/// These tests first reproduce the pre-fix hidden side effects (every timeline wrote
/// `Notes/Welcome.md` + `Notes/Project.md` into a temp directory with no cleanup), then
/// prove the new default (`.noWorkspace`) has no filesystem side effects, that
/// `.ephemeralWorkspace` cleans up deterministically, and that seed notes are configurable.
@Suite("Workspace profile lifecycle & retention (PKRR-029)")
struct WorkspaceProfileLifecycleTests {
    // MARK: - Regression: the pre-fix behavior, now opt-in via .hostManaged

    @Test(".hostManaged writes Notes/Welcome.md and Notes/Project.md (preserved pre-PKRR-029 behavior)")
    func hostManagedWritesDefaultNotes() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: root))

        let timeline = try await timelineManager.createTimeline()

        let workingDir = try #require(timeline.workingDirectory)
        let notesDir = URL(fileURLWithPath: workingDir).appendingPathComponent("Notes")
        let welcome = try String(
            contentsOf: notesDir.appendingPathComponent("Welcome.md"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: notesDir.appendingPathComponent("Project.md"),
            encoding: .utf8
        )
        #expect(welcome.contains("Welcome"))
        #expect(project.contains("Active Objective"))
        #expect(!timeline.attachedWorkspaceIds.isEmpty)
    }

    @Test(".hostManaged does NOT remove the directory on permanent deletion (host owns retention)")
    func hostManagedLeavesDirectoryOnDelete() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: root))

        let timeline = try await timelineManager.createTimeline()
        let dir = URL(fileURLWithPath: try #require(timeline.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: dir.path))

        // Permanent deletion removes the persisted records but leaves the directory: the host
        // owns retention. This is the pre-PKRR-029 leak, now scoped to .hostManaged only.
        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)
        #expect(result.isComplete)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Default: no filesystem side effects

    @Test(".noWorkspace (default) creates no directory, writes no notes, and leaves workingDirectory nil")
    func noWorkspaceDefaultHasNoSideEffects() async throws {
        let timelineManager = TimelineManager(workspaceProfile: .noWorkspace)

        let timeline = try await timelineManager.createTimeline()

        #expect(timeline.workingDirectory == nil)
        #expect(timeline.attachedWorkspaceIds.isEmpty)
    }

    @Test("A minimal PositronicKit facade (no workspaceRoot) has no filesystem side effects")
    func minimalFacadeHasNoFilesystemSideEffects() async throws {
        let kit = PositronicKit(languageModel: UnconfiguredLLMService())

        let timeline = try await kit.timelineManager.createTimeline()

        #expect(timeline.workingDirectory == nil)
        #expect(timeline.attachedWorkspaceIds.isEmpty)
    }

    @Test("RuntimeConfiguration.default resolves to .noWorkspace")
    func runtimeConfigurationDefaultIsNoWorkspace() {
        let config = PositronicKit.RuntimeConfiguration.default
        if case .noWorkspace = config.workspaceProfile {
            // ok
        } else {
            Issue.record("Expected .noWorkspace, got \(config.workspaceProfile)")
        }
        #expect(config.workspaceRoot == nil)
    }

    @Test("RuntimeConfiguration(workspaceRoot:) maps to .hostManaged for backward compatibility")
    func runtimeConfigurationLegacyWorkspaceRootMapsToHostManaged() {
        let root = URL(fileURLWithPath: "/tmp/pk-legacy")
        let config = PositronicKit.RuntimeConfiguration(workspaceRoot: root)
        if case let .hostManaged(resolvedRoot, seedNotes) = config.workspaceProfile {
            #expect(resolvedRoot == root)
            #expect(seedNotes == .default)
        } else {
            Issue.record("Expected .hostManaged, got \(config.workspaceProfile)")
        }
    }

    // MARK: - Ephemeral: deterministic cleanup

    @Test(".ephemeralWorkspace creates the directory and seeds default notes")
    func ephemeralCreatesDirectoryAndNotes() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(
            workspaceProfile: .ephemeralWorkspace(root: root)
        )

        let timeline = try await timelineManager.createTimeline()
        let dir = URL(fileURLWithPath: try #require(timeline.workingDirectory))

        #expect(FileManager.default.fileExists(atPath: dir.path))
        let notesDir = dir.appendingPathComponent("Notes")
        #expect(FileManager.default.fileExists(atPath: notesDir.appendingPathComponent("Welcome.md").path))
    }

    @Test(".ephemeralWorkspace removes the directory on permanent deletion")
    func ephemeralCleansUpOnPermanentDelete() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(
            workspaceProfile: .ephemeralWorkspace(root: root)
        )

        let timeline = try await timelineManager.createTimeline()
        let dir = URL(fileURLWithPath: try #require(timeline.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: dir.path))

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)
        #expect(result.isComplete)

        // The scratch directory is gone — no leftover temp data.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test(".ephemeralWorkspace removes the directory on memory eviction")
    func ephemeralCleansUpOnEviction() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(
            workspaceProfile: .ephemeralWorkspace(root: root)
        )

        let timeline = try await timelineManager.createTimeline()
        let dir = URL(fileURLWithPath: try #require(timeline.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: dir.path))

        await timelineManager.evictTimelineFromMemory(id: timeline.id)

        // Eviction ends the ephemeral workspace's life: the scratch directory is removed.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(await timelineManager.timeline(id: timeline.id) == nil)
    }

    @Test(".ephemeralWorkspace cleans a non-cached timeline's directory on permanent deletion")
    func ephemeralCleansNonCachedOnPermanentDelete() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(
            workspaceProfile: .ephemeralWorkspace(root: root)
        )

        let timeline = try await timelineManager.createTimeline()
        let dir = URL(fileURLWithPath: try #require(timeline.workingDirectory))

        // Evict from memory first, so deleteTimelinePermanently must fetch from persistence.
        await timelineManager.evictTimelineFromMemory(id: timeline.id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // Re-create the directory to simulate the cached-eviction having already cleaned it;
        // then delete permanently and confirm the non-cached path also cleans up.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)
        #expect(result.isComplete)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Configurable seed notes

    @Test(".ephemeralWorkspace with seedNotes: .none writes no Notes directory")
    func ephemeralNoSeedNotes() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineManager = TimelineManager(
            workspaceProfile: .ephemeralWorkspace(root: root, seedNotes: .none)
        )

        let timeline = try await timelineManager.createTimeline()
        let notesDir = URL(fileURLWithPath: try #require(timeline.workingDirectory))
            .appendingPathComponent("Notes")

        #expect(!FileManager.default.fileExists(atPath: notesDir.path))
    }

    @Test(".hostManaged with custom seedNotes replaces the default opinionated content")
    func customSeedNotes() async throws {
        let root = makeUniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = WorkspaceSeedNotes(
            WorkspaceSeedNote(filename: "README.md", content: "custom workspace intro")
        )
        let timelineManager = TimelineManager(
            workspaceProfile: .hostManaged(root: root, seedNotes: custom)
        )

        let timeline = try await timelineManager.createTimeline()
        let notesDir = URL(fileURLWithPath: try #require(timeline.workingDirectory))
            .appendingPathComponent("Notes")

        let readme = try String(
            contentsOf: notesDir.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        #expect(readme == "custom workspace intro")
        // Default notes are not written when a custom set is supplied.
        #expect(!FileManager.default.fileExists(atPath: notesDir.appendingPathComponent("Welcome.md").path))
        #expect(!FileManager.default.fileExists(atPath: notesDir.appendingPathComponent("Project.md").path))
    }

    // MARK: - Helpers

    private func makeUniqueRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
