import Foundation
import PKContracts
import PKUtilities
import PositronicKit

/// Explicit test composition root for PKRuntime runtime tests.
///
/// `TestRuntime` is the single deep fixture for runtime suites. It wires every store and
/// service from one coherent persistence backing and builds the `PKRuntime` facade through the
/// public ``PKRuntime/Configuration``, so a test never copies construction wiring inline.
///
/// Construct one per test with a unique `workspaceRoot`, then read its fields directly or access
/// `runtime` for a fully-wired facade. Consumer-facing tests use the facade's capability values
/// and assert durable facts through ``repository`` (a `TimelineRuntimeRepository`) or a
/// ``TurnHandle``, rather than reaching into managers.
///
/// Customization covers the wiring variants the suite used to spell inline:
/// - ``llm`` is the scripted language model; its `mockClient` drives streamed and one-shot output.
/// - ``persistence`` is an in-memory composite double shared by every store. Pass it to inspect
///   state or flip failure switches. It is the default repository.
/// - ``persistenceConfiguration`` overrides the default in-memory wiring when a test needs a
///   specific repository, a workspace-binding repository, or explicit store identities.
/// - ``runtime`` overrides the default runtime knobs (Workspace profile, customization,
///   `terminalCommitStallLimit`, degradation policy, and so on).
/// - ``generationParameters`` sets the facade's default generation parameters.
/// - ``runtimeBuilder`` is the escape hatch for the clock seam: a `@testable` suite can build the
///   facade with the internal clock initializer while still constructing through `TestRuntime`.
public struct TestRuntime: Sendable {
    /// The scripted language model wired into the runtime. Set `llm.mockClient` fields to script
    /// streamed chunks, one-shot responses, and failure behavior.
    public let llm: MockLLMService

    /// The composite in-memory persistence double. Every store defaults to this object unless
    /// ``persistenceConfiguration`` overrides the wiring.
    public let persistence: MockPersistenceService

    /// The runtime's cohesive Timeline/Turn repository, the surface for durable assertions.
    ///
    /// This is ``persistence`` by default, or the `runtimeRepository` of the supplied
    /// ``persistenceConfiguration``.
    public let repository: any TimelineRuntimeRepository

    private let core: PKRuntime

    /// The `PKRuntime` facade wired to this runtime's stores, managers, and services.
    public var runtime: PKRuntime {
        core
    }

    /// The Timeline capability of the wired facade.
    public var timelines: TimelineCapability {
        core.timelines
    }

    /// The Agent capability of the wired facade.
    public var agents: AgentCapability {
        core.agents
    }

    /// The Workspace capability of the wired facade.
    public var workspaces: WorkspaceCapability {
        core.workspaces
    }

    /// The composite persistence double viewed as a Timeline-persistence store.
    public var timelinePersistence: any TimelinePersistenceProtocol {
        persistence
    }

    /// Returns a unique temporary directory suitable for one test's `workspaceRoot`.
    public static func uniqueWorkspaceRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// Creates a fully-wired runtime through the public `PKRuntime.Configuration`.
    ///
    /// - Parameters:
    ///   - workspaceRoot: Unique root directory for this runtime's workspaces. It supplies the
    ///     default `.hostManaged` Workspace profile when ``runtime`` is `nil`.
    ///   - llm: Scripted language model. Defaults to a fresh mock.
    ///   - persistence: Composite in-memory persistence double shared by every store and the
    ///     default repository. Defaults to a fresh mock.
    ///   - persistenceConfiguration: Explicit persistence wiring. When `nil`, every store is the
    ///     supplied ``persistence`` double, which is the in-memory default.
    ///   - runtime: Explicit non-store runtime knobs. When `nil`, the fixture uses a
    ///     `.hostManaged(root: workspaceRoot)` profile with ``workspaceCreator``.
    ///   - generationParameters: The facade's default generation parameters, or `nil` for provider
    ///     defaults.
    ///   - workspaceCreator: Workspace factory for the default profile. Ignored when ``runtime``
    ///     supplies its own profile. Defaults to `MockWorkspaceCreator`.
    ///   - runtimeBuilder: Builds the facade from the assembled configuration. Defaults to the
    ///     public `PKRuntime(configuration:)` entry point; a `@testable` suite can instead call the
    ///     internal clock initializer.
    public init(
        workspaceRoot: URL,
        llm: MockLLMService = MockLLMService(),
        persistence: MockPersistenceService = MockPersistenceService(),
        persistenceConfiguration: PKRuntime.PersistenceConfiguration? = nil,
        runtime: PKRuntime.RuntimeConfiguration? = nil,
        generationParameters: GenerationParameters? = nil,
        workspaceCreator: (any WorkspaceFactory)? = nil,
        runtimeBuilder: (@Sendable (PKRuntime.Configuration) -> PKRuntime)? = nil
    ) {
        self.llm = llm
        self.persistence = persistence

        let resolvedPersistence = persistenceConfiguration ?? PKRuntime.PersistenceConfiguration(
            runtimeRepository: persistence,
            workspacePersistence: persistence,
            agentStore: persistence,
            requestOriginStore: persistence
        )
        repository = resolvedPersistence.runtimeRepository

        let resolvedRuntime = runtime ?? PKRuntime.RuntimeConfiguration(
            workspaceProfile: .hostManaged(root: workspaceRoot),
            workspaceCreator: workspaceCreator ?? MockWorkspaceCreator()
        )

        let configuration = PKRuntime.Configuration(
            languageModel: llm,
            persistence: resolvedPersistence,
            runtime: resolvedRuntime,
            generationParameters: generationParameters
        )
        core = runtimeBuilder?(configuration) ?? PKRuntime(configuration: configuration)
    }
}
