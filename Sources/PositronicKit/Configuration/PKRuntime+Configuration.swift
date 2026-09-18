import Foundation
import Logging
import PKContracts
import PKUtilities

public extension PKRuntime {
    /// Groups the language model, persistence, runtime, and generation concerns for construction.
    struct Configuration: Sendable {
        /// The language model the runtime uses for generation and streaming.
        public let languageModel: any LLMStreamClient
        /// The persistence stores the runtime writes to.
        public let persistence: PersistenceConfiguration
        /// The non-store runtime knobs and bounded customization roles.
        public let runtime: RuntimeConfiguration
        /// The default generation parameters applied when a Turn carries no explicit override.
        public let generationParameters: GenerationParameters?
        /// The logging configuration used for runtime diagnostics.
        public let logging: LoggingConfiguration

        /// Creates a grouped configuration for the supported production entry point.
        ///
        /// - Parameters:
        ///   - languageModel: The language model the runtime uses for generation and streaming.
        ///   - persistence: The persistence stores the runtime writes to.
        ///   - runtime: The non-store runtime knobs and bounded customization roles.
        ///   - generationParameters: The default generation parameters, or `nil` for provider defaults.
        ///   - logging: The logging configuration used for runtime diagnostics.
        public init(
            languageModel: any LLMStreamClient,
            persistence: PersistenceConfiguration,
            runtime: RuntimeConfiguration = .default,
            generationParameters: GenerationParameters? = nil,
            logging: LoggingConfiguration = .default
        ) {
            self.languageModel = languageModel
            self.persistence = persistence
            self.runtime = runtime
            self.generationParameters = generationParameters
            self.logging = logging
        }

        /// Creates a grouped configuration from a provider-package value.
        ///
        /// The durable counterpart to ``PKRuntime/init(provider:)``: it resolves the
        /// provider's configuration and client into the same ``LLMService`` the facade's
        /// in-memory provider path uses, so applications still never assemble
        /// ``LLMService`` or ``LLMClientSet`` themselves. Pass the result to
        /// ``PKRuntime/init(configuration:)``.
        ///
        /// - Parameters:
        ///   - provider: The configured provider value a provider package created.
        ///   - persistence: The persistence stores the runtime writes to.
        ///   - runtime: The non-store runtime knobs and bounded customization roles.
        ///   - generationParameters: The default generation parameters, or `nil` for provider defaults.
        ///   - logging: The logging configuration used for runtime diagnostics.
        public init(
            provider: ConfiguredLLMProvider,
            persistence: PersistenceConfiguration,
            runtime: RuntimeConfiguration = .default,
            generationParameters: GenerationParameters? = nil,
            logging: LoggingConfiguration = .default
        ) {
            self.init(
                languageModel: LLMService(provider: provider),
                persistence: persistence,
                runtime: runtime,
                generationParameters: generationParameters,
                logging: logging
            )
        }
    }

    /// Groups the persistence stores the runtime writes to. A cohesive runtime repository is
    /// required because it is the atomic owner of Timeline history and Turn transitions.
    ///
    /// Use ``validateDurability()`` to detect mixed-durability configurations (some stores
    /// durable, others in-memory) that can lose data on restart. Use
    /// ``fullyPersistent(runtimeRepository:workspacePersistence:toolPersistence:agentStore:requestOriginStore:workspaceBindingRepository:)``
    /// when all stores must be explicitly provided for full durability.
    struct PersistenceConfiguration: Sendable {
        /// Cohesive owner for Timeline history and Turn lifecycle.
        public let runtimeRepository: any TimelineRuntimeRepository
        /// The durable store for Workspace file and metadata state.
        public let workspacePersistence: any WorkspaceStore
        /// The durable authority for ordinary Workspace-to-Timeline bindings.
        public let workspaceBindingRepository: any WorkspaceBindingRepository
        /// The durable store for tool execution records.
        public let toolPersistence: any ToolPersistenceProtocol
        /// The durable store for Agent identities.
        public let agentStore: any AgentStoreProtocol
        /// The durable store for request-origin records.
        public let requestOriginStore: any RequestOriginStoreProtocol

        /// Creates a persistence configuration, defaulting omitted stores to in-memory.
        public init(
            runtimeRepository: any TimelineRuntimeRepository,
            workspacePersistence: any WorkspaceStore? = nil,
            toolPersistence: any ToolPersistenceProtocol? = nil,
            agentStore: any AgentStoreProtocol? = nil,
            requestOriginStore: any RequestOriginStoreProtocol? = nil,
            workspaceBindingRepository: any WorkspaceBindingRepository? = nil
        ) {
            let resolvedWorkspaceStore = workspacePersistence ?? InMemoryWorkspacePersistence()
            self.runtimeRepository = runtimeRepository
            self.workspacePersistence = resolvedWorkspaceStore
            self.workspaceBindingRepository = workspaceBindingRepository
                ?? (runtimeRepository as? any WorkspaceBindingRepository)
                ?? InMemoryWorkspaceBindingRepository()
            self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
            self.agentStore = agentStore ?? InMemoryAgentStore()
            self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        }

        /// A fully in-memory persistence configuration, suitable for prototyping and tests.
        public static func inMemory() -> PersistenceConfiguration {
            PersistenceConfiguration(runtimeRepository: InMemoryTimelineRuntimeRepository())
        }

        /// Requires the runtime, workspace, tool, agent, and request-origin stores explicitly —
        /// the "full durability" entry point for production hosts (Monad, Shuttle). Unlike the
        /// optional-store init, no required store can
        /// silently default to in-memory.
        public static func fullyPersistent(
            runtimeRepository: any TimelineRuntimeRepository,
            workspacePersistence: any WorkspaceStore,
            toolPersistence: any ToolPersistenceProtocol,
            agentStore: any AgentStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            workspaceBindingRepository: any WorkspaceBindingRepository? = nil
        ) -> PersistenceConfiguration {
            PersistenceConfiguration(
                runtimeRepository: runtimeRepository,
                workspacePersistence: workspacePersistence,
                toolPersistence: toolPersistence,
                agentStore: agentStore,
                requestOriginStore: requestOriginStore,
                workspaceBindingRepository: workspaceBindingRepository
            )
        }

        /// Classifies each store as `.durable` or `.ephemeral` based on its `isDurable` property.
        ///
        /// Use `report.isMixed` to detect configurations where some stores survive restart
        /// and others do not — a data-consistency risk. Use `report.ephemeralStoreNames` to
        /// identify which specific stores are ephemeral.
        public func validateDurability() -> DurabilityReport {
            DurabilityReport(
                runtimeRepository: runtimeRepository.isDurable ? .durable : .ephemeral,
                workspacePersistence: workspacePersistence.isDurable ? .durable : .ephemeral,
                workspaceBindingRepository: workspaceBindingRepository.isDurable ? .durable : .ephemeral,
                toolPersistence: toolPersistence.isDurable ? .durable : .ephemeral,
                agentStore: agentStore.isDurable ? .durable : .ephemeral,
                requestOriginStore: requestOriginStore.isDurable ? .durable : .ephemeral
            )
        }

    }

    /// Whether a persistence store survives process restart.
    enum StoreDurability: Sendable, Equatable {
        /// The store is backed by a durable database (GRDB, SwiftData) and survives restart.
        case durable
        /// The store is in-memory/ephemeral and loses all data on restart.
        case ephemeral
    }

    /// A cross-store durability classification produced by
    /// ``PersistenceConfiguration/validateDurability()``.
    ///
    /// `isMixed` is `true` when the configuration has both `.durable` and `.ephemeral`
    /// stores — a data-consistency risk because durable stores may reference entities
    /// (timelines, workspaces, agents) that will be missing after restart.
    struct DurabilityReport: Sendable, Equatable {
        /// The durability classification of the Timeline history and Turn lifecycle owner.
        public let runtimeRepository: StoreDurability
        /// The durability classification of the Workspace file and metadata store.
        public let workspacePersistence: StoreDurability
        /// The durability classification of the Workspace-to-Timeline binding authority.
        public let workspaceBindingRepository: StoreDurability
        /// The durability classification of the tool execution record store.
        public let toolPersistence: StoreDurability
        /// The durability classification of the Agent identity store.
        public let agentStore: StoreDurability
        /// The durability classification of the request-origin record store.
        public let requestOriginStore: StoreDurability

        /// Creates a cross-store durability classification from per-store values.
        public init(
            runtimeRepository: StoreDurability,
            workspacePersistence: StoreDurability,
            workspaceBindingRepository: StoreDurability,
            toolPersistence: StoreDurability,
            agentStore: StoreDurability,
            requestOriginStore: StoreDurability
        ) {
            self.runtimeRepository = runtimeRepository
            self.workspacePersistence = workspacePersistence
            self.workspaceBindingRepository = workspaceBindingRepository
            self.toolPersistence = toolPersistence
            self.agentStore = agentStore
            self.requestOriginStore = requestOriginStore
        }

        /// Whether the configuration mixes durable and ephemeral stores.
        public var isMixed: Bool {
            let all: [StoreDurability] = [
                runtimeRepository, workspacePersistence, workspaceBindingRepository,
                toolPersistence, agentStore, requestOriginStore,
            ]
            return all.contains(.durable) && all.contains(.ephemeral)
        }

        /// The label of each store classified as `.ephemeral`, in declaration order.
        public var ephemeralStoreNames: [String] {
            var names: [String] = []
            if runtimeRepository == .ephemeral { names.append("runtimeRepository") }
            if workspacePersistence == .ephemeral { names.append("workspacePersistence") }
            if workspaceBindingRepository == .ephemeral { names.append("workspaceBindingRepository") }
            if toolPersistence == .ephemeral { names.append("toolPersistence") }
            if agentStore == .ephemeral { names.append("agentStore") }
            if requestOriginStore == .ephemeral { names.append("requestOriginStore") }
            return names
        }

        /// The warning message logged on mixed durability, or `nil` when the configuration
        /// is uniformly durable or uniformly ephemeral.
        public var mixedDurabilityWarning: String? {
            guard isMixed else { return nil }
            return "Mixed durability: the following stores are in-memory and will not survive restart: \(ephemeralStoreNames.joined(separator: ", ")). Data persisted to durable stores may reference entities that will be missing after restart."
        }
    }

    /// Groups the non-store runtime knobs and the four bounded customization roles.
    struct RuntimeConfiguration: Sendable {
        /// How the per-timeline filesystem workspace is provisioned.
        public let workspaceProfile: WorkspaceProfile
        /// Creates per-timeline workspace directories when the selected profile requires them.
        public let workspaceCreator: any WorkspaceFactory
        /// The bounded Agent context, Turn context, activity, and outcome roles.
        public let customization: RuntimeCustomization
        /// Controls which tools the runtime may expose and execute.
        public let runtimeToolPolicy: RuntimeToolPolicy
        /// Controls whether runtime tool calls require approval.
        public let toolApprovalPolicy: any ToolApprovalPolicy
        /// Controls diagnostic response snapshots.
        public let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
        /// Controls whether required turn degradations fail the turn.
        public let degradationPolicy: TurnDegradationPolicy

        /// How long, in seconds, a Turn's terminal commit may stay pending before admission
        /// treats the Turn as abandoned and interrupts it (ADR 0010).
        ///
        /// A non-finite or non-positive value falls back to the 300-second default. The limit is
        /// measured with the injected runtime clock, and it bounds how long a Timeline stays busy
        /// for a stalled commit — it never bounds the commit itself, so the durable outcome is
        /// never ambiguous.
        public let terminalCommitStallLimit: TimeInterval

        /// Maximum idle time, in seconds, between streamed model chunks before a Turn fails
        /// with `streamTimedOut`.
        ///
        /// Clamped to one millisecond ... one day. The bounds exist only to keep unusable values
        /// out of the stream watchdog: a zero or negative timeout would fail every Turn the
        /// instant it starts, and a huge or infinite one would trap in `Duration.seconds(_:)`.
        /// This initializer is not failable, so out-of-range values are clamped and non-finite
        /// ones fall back to the 60-second default.
        public let streamTimeout: TimeInterval

        /// - Parameters:
        ///   - workspaceProfile: How the per-timeline filesystem workspace is provisioned.
        ///     Defaults to `.noWorkspace` (no filesystem side effects). Pass `.hostManaged(root:)`
        ///     to use a host-owned directory, or
        ///     `.ephemeralWorkspace(root:)` for a self-cleaning scratch directory.
        ///   - workspaceCreator: Creates per-timeline workspace directories when the selected
        ///     profile requires them.
        ///   - customization: The bounded Agent context, Turn context, activity, and outcome roles.
        ///   - runtimeToolPolicy: Controls which tools the runtime may expose and execute.
        ///   - toolApprovalPolicy: Controls whether runtime tool calls require approval.
        ///   - diagnosticSnapshotConfiguration: Controls diagnostic response snapshots.
        ///   - degradationPolicy: Controls whether required turn degradations fail the turn.
        ///   - streamTimeout: Maximum idle time between streamed model chunks, in seconds.
        ///     Clamped to one millisecond ... one day; a non-finite value falls back to 60.
        ///   - terminalCommitStallLimit: How long a pending terminal commit may stay pending
        ///     before admission interrupts the Turn, in seconds. A non-finite or non-positive
        ///     value falls back to 300.
        public init(
            workspaceProfile: WorkspaceProfile = .noWorkspace,
            workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
            customization: RuntimeCustomization = .default,
            runtimeToolPolicy: RuntimeToolPolicy = .default,
            toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
            degradationPolicy: TurnDegradationPolicy = .failRequired,
            streamTimeout: TimeInterval = 60,
            terminalCommitStallLimit: TimeInterval = 300
        ) {
            self.workspaceProfile = workspaceProfile
            self.workspaceCreator = workspaceCreator
            self.customization = customization
            self.runtimeToolPolicy = runtimeToolPolicy
            self.toolApprovalPolicy = toolApprovalPolicy
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
            self.degradationPolicy = degradationPolicy
            self.streamTimeout = TurnEngine.Dependencies.resolvedStreamTimeout(streamTimeout)
            self.terminalCommitStallLimit = Self.resolvedTerminalCommitStallLimit(terminalCommitStallLimit)
        }

        /// A finite, positive stall limit, falling back to the 300-second default.
        static func resolvedTerminalCommitStallLimit(_ requested: TimeInterval) -> TimeInterval {
            guard requested.isFinite, requested > 0 else { return 300 }
            return requested
        }

        /// The default runtime configuration: no workspaces or customization, deny-all tool approval.
        public static var `default`: RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a facade from a grouped configuration. This is the supported production entry
    /// point; use `PKRuntime(languageModel:)` for prototyping.
    ///
    /// During construction the persistence configuration is checked for mixed durability
    /// (some stores durable, others in-memory). If mixed, a `.warning` is logged naming the
    /// specific ephemeral stores. The warning is non-fatal — it is the guardrail against
    /// accidentally losing timelines, workspaces, agents, or tool state on restart.
    convenience init(configuration: Configuration) {
        self.init(
            configuration: configuration,
            sharedRegistry: TimelinePromptJournals(),
            additionalStages: []
        )
    }
}
