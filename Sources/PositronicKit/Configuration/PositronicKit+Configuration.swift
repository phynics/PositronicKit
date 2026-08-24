import Foundation
import Logging
import PKContracts
import PKUtilities

public extension PositronicKit {
    /// Groups provider-facing services used by the runtime.
    /// Provider configuration for the language model used by the runtime.
    struct ProviderConfiguration: Sendable {
        public let languageModel: any LLMStreamClient & LLMUtilityClient

        public init(
            languageModel: any LLMStreamClient & LLMUtilityClient
        ) {
            self.languageModel = languageModel
        }
    }

    /// Groups provider, persistence, runtime, and generation concerns for construction.
    struct Configuration: Sendable {
        public let provider: ProviderConfiguration
        public let persistence: PersistenceConfiguration
        public let runtime: RuntimeConfiguration
        public let generationParameters: GenerationParameters?
        public let logging: LoggingConfiguration

        public init(
            provider: ProviderConfiguration,
            persistence: PersistenceConfiguration,
            runtime: RuntimeConfiguration = .default,
            generationParameters: GenerationParameters? = nil,
            logging: LoggingConfiguration = .default
        ) {
            self.provider = provider
            self.persistence = persistence
            self.runtime = runtime
            self.generationParameters = generationParameters
            self.logging = logging
        }
    }

    /// Groups the persistence stores the runtime writes to. Every store is optional;
    /// omitted stores default to their in-memory implementation, so partial persistence
    /// setups (e.g. only a real message store) work without boilerplate. Supplying a runtime
    /// repository makes one cohesive owner the Thread and message store used by Turn admission
    /// and tool ordering.
    ///
    /// Use ``validateDurability()`` to detect mixed-durability configurations (some stores
    /// durable, others in-memory) that can lose data on restart. Use
    /// `fullyPersistent(messageStore:threadPersistence:workspacePersistence:toolPersistence:agentStore:requestOriginStore:runtimeRepository:workspaceBindingRepository:)`
    /// when all six stores must be explicitly provided for full durability.
    struct PersistenceConfiguration: Sendable {
        /// Optional cohesive owner for Thread history and Turn transitions. When supplied
        /// without explicit low-level stores, it is used for both thread and message access.
        public let runtimeRepository: (any ThreadRuntimeRepository)?
        public let messageStore: any ThreadMessageStoreProtocol
        public let threadPersistence: any ThreadPersistenceProtocol
        public let workspacePersistence: any WorkspaceStore
        public let workspaceBindingRepository: any WorkspaceBindingRepository
        public let toolPersistence: any ToolPersistenceProtocol
        public let agentStore: any AgentStoreProtocol
        public let requestOriginStore: any RequestOriginStoreProtocol

        /// Legacy compatibility path: independent Thread/message stores do not provide v4
        /// atomic Turn admission or terminal-message semantics. Supply `runtimeRepository` for
        /// the supported v4 configuration.
        public init(
            messageStore: (any ThreadMessageStoreProtocol)? = nil,
            threadPersistence: (any ThreadPersistenceProtocol)? = nil,
            workspacePersistence: (any WorkspaceStore)? = nil,
            toolPersistence: (any ToolPersistenceProtocol)? = nil,
            agentStore: (any AgentStoreProtocol)? = nil,
            requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
            runtimeRepository: (any ThreadRuntimeRepository)? = nil,
            workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil
        ) {
            let resolvedRepository = runtimeRepository
                ?? (messageStore == nil && threadPersistence == nil ? InMemoryThreadRuntimeRepository() : nil)
            let resolvedWorkspaceStore = workspacePersistence ?? InMemoryWorkspacePersistence()
            self.runtimeRepository = resolvedRepository
            self.messageStore = resolvedRepository ?? messageStore ?? InMemoryMessageStore()
            self.threadPersistence = resolvedRepository ?? threadPersistence ?? InMemoryThreadPersistence()
            self.workspacePersistence = resolvedWorkspaceStore
            self.workspaceBindingRepository = workspaceBindingRepository
                ?? (resolvedRepository as? any WorkspaceBindingRepository)
                ?? (resolvedWorkspaceStore as? any WorkspaceBindingRepository)
                ?? InMemoryWorkspaceBindingRepository()
            self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
            self.agentStore = agentStore ?? InMemoryAgentStore()
            self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        }

        /// Creates a persistence configuration from the canonical thread store.
        /// Legacy compatibility path: independent Thread/message stores do not provide v4
        /// atomic Turn admission or terminal-message semantics. Supply `runtimeRepository` for
        /// the supported v4 configuration.
        public init(
            messageStore: (any ThreadMessageStoreProtocol)? = nil,
            threadPersistence: any ThreadPersistenceProtocol,
            workspacePersistence: (any WorkspaceStore)? = nil,
            toolPersistence: (any ToolPersistenceProtocol)? = nil,
            agentStore: (any AgentStoreProtocol)? = nil,
            requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
            runtimeRepository: (any ThreadRuntimeRepository)? = nil,
            workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil
        ) {
            let resolvedWorkspaceStore = workspacePersistence ?? InMemoryWorkspacePersistence()
            self.runtimeRepository = runtimeRepository
            self.messageStore = runtimeRepository ?? messageStore ?? InMemoryMessageStore()
            self.threadPersistence = runtimeRepository ?? threadPersistence
            self.workspacePersistence = resolvedWorkspaceStore
            self.workspaceBindingRepository = workspaceBindingRepository
                ?? (runtimeRepository as? any WorkspaceBindingRepository)
                ?? (resolvedWorkspaceStore as? any WorkspaceBindingRepository)
                ?? InMemoryWorkspaceBindingRepository()
            self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
            self.agentStore = agentStore ?? InMemoryAgentStore()
            self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        }

        /// A fully in-memory persistence configuration, suitable for prototyping and tests.
        public static func inMemory() -> PersistenceConfiguration {
            PersistenceConfiguration(runtimeRepository: InMemoryThreadRuntimeRepository())
        }

        /// Requires all six stores explicitly — the "full durability" entry point for
        /// production hosts (Monad, Shuttle). Unlike the optional-store init, no store can
        /// silently default to in-memory.
        /// Legacy compatibility path: independent stores cannot provide atomic v4 Turn admission
        /// or terminal-message transitions. Supply a `ThreadRuntimeRepository` instead.
        public static func fullyPersistent(
            messageStore: any ThreadMessageStoreProtocol,
            threadPersistence: any ThreadPersistenceProtocol,
            workspacePersistence: any WorkspaceStore,
            toolPersistence: any ToolPersistenceProtocol,
            agentStore: any AgentStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            runtimeRepository: (any ThreadRuntimeRepository)? = nil,
            workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil
        ) -> PersistenceConfiguration {
            PersistenceConfiguration(
                messageStore: messageStore,
                threadPersistence: threadPersistence,
                workspacePersistence: workspacePersistence,
                toolPersistence: toolPersistence,
                agentStore: agentStore,
                requestOriginStore: requestOriginStore,
                runtimeRepository: runtimeRepository,
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
                messageStore: messageStore.isDurable ? .durable : .ephemeral,
                threadPersistence: threadPersistence.isDurable ? .durable : .ephemeral,
                workspacePersistence: workspacePersistence.isDurable ? .durable : .ephemeral,
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
    /// (threads, workspaces, agents) that will be missing after restart.
    struct DurabilityReport: Sendable, Equatable {
        public let messageStore: StoreDurability
        public let threadPersistence: StoreDurability
        public let workspacePersistence: StoreDurability
        public let toolPersistence: StoreDurability
        public let agentStore: StoreDurability
        public let requestOriginStore: StoreDurability

        public init(
            messageStore: StoreDurability,
            threadPersistence: StoreDurability,
            workspacePersistence: StoreDurability,
            toolPersistence: StoreDurability,
            agentStore: StoreDurability,
            requestOriginStore: StoreDurability
        ) {
            self.messageStore = messageStore
            self.threadPersistence = threadPersistence
            self.workspacePersistence = workspacePersistence
            self.toolPersistence = toolPersistence
            self.agentStore = agentStore
            self.requestOriginStore = requestOriginStore
        }

        public var isMixed: Bool {
            let all: [StoreDurability] = [
                messageStore, threadPersistence, workspacePersistence,
                toolPersistence, agentStore, requestOriginStore,
            ]
            return all.contains(.durable) && all.contains(.ephemeral)
        }

        /// The label of each store classified as `.ephemeral`, in declaration order.
        public var ephemeralStoreNames: [String] {
            var names: [String] = []
            if messageStore == .ephemeral { names.append("messageStore") }
            if threadPersistence == .ephemeral { names.append("threadPersistence") }
            if workspacePersistence == .ephemeral { names.append("workspacePersistence") }
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
        public let workspaceProfile: WorkspaceProfile
        public let workspaceCreator: any WorkspaceFactory
        public let customization: RuntimeCustomization
        public let runtimeToolPolicy: RuntimeToolPolicy
        public let toolApprovalPolicy: any ToolApprovalPolicy
        public let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
        public let degradationPolicy: TurnDegradationPolicy

        /// The workspace root this configuration resolves to, if any (PKRR-029).
        ///
        /// Returns `nil` for `.noWorkspace`. Preserved for backward compatibility with callers
        /// that read the resolved root; prefer reading `workspaceProfile` directly.
        public var workspaceRoot: URL? { workspaceProfile.catalogRoot }

        /// - Parameters:
        ///   - workspaceProfile: How the per-thread filesystem workspace is provisioned.
        ///     Defaults to `.noWorkspace` (no filesystem side effects). Pass `.hostManaged(root:)`
        ///     to preserve the pre-PKRR-029 behavior of an explicit workspace root, or
        ///     `.ephemeralWorkspace(root:)` for a self-cleaning scratch directory.
        ///   - workspaceRoot: Legacy shorthand. When non-`nil` and `workspaceProfile` is omitted,
        ///     maps to `.hostManaged(root: workspaceRoot, seedNotes: .default)`.
        ///   - workspaceCreator: Creates per-thread workspace directories when the selected
        ///     profile requires them.
        ///   - customization: The bounded Agent context, Turn context, activity, and outcome roles.
        ///   - runtimeToolPolicy: Controls which tools the runtime may expose and execute.
        ///   - toolApprovalPolicy: Controls whether runtime tool calls require approval.
        ///   - diagnosticSnapshotConfiguration: Controls diagnostic response snapshots.
        ///   - degradationPolicy: Controls whether required turn degradations fail the turn.
        public init(
            workspaceProfile: WorkspaceProfile? = nil,
            workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
            customization: RuntimeCustomization = .default,
            runtimeToolPolicy: RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
            degradationPolicy: TurnDegradationPolicy = .failRequired
        ) {
            if let workspaceProfile {
                self.workspaceProfile = workspaceProfile
            } else if let workspaceRoot {
                self.workspaceProfile = .hostManaged(root: workspaceRoot, seedNotes: .default)
            } else {
                self.workspaceProfile = .noWorkspace
            }
            self.workspaceCreator = workspaceCreator
            self.customization = customization
            self.runtimeToolPolicy = runtimeToolPolicy
            self.toolApprovalPolicy = toolApprovalPolicy
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
            self.degradationPolicy = degradationPolicy
        }

        /// The default runtime configuration: no workspaces or customization, deny-all tool approval.
        public static var `default`: RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }

    /// Creates a facade from a grouped configuration. This is the supported production entry
    /// point; use `PositronicKit(languageModel:)` for prototyping.
    ///
    /// During construction the persistence configuration is checked for mixed durability
    /// (some stores durable, others in-memory). If mixed, a `.warning` is logged naming the
    /// specific ephemeral stores. The warning is non-fatal — it is the guardrail against
    /// accidentally losing threads, workspaces, agents, or tool state on restart.
    convenience init(configuration: Configuration) {
        self.init(
            languageModel: configuration.provider.languageModel,
            messageStore: configuration.persistence.messageStore,
            runtimeRepository: configuration.persistence.runtimeRepository,
            workspaceBindingRepository: configuration.persistence.workspaceBindingRepository,
            agentStore: configuration.persistence.agentStore,
            requestOriginStore: configuration.persistence.requestOriginStore,
            threadPersistence: configuration.persistence.threadPersistence,
            workspacePersistence: configuration.persistence.workspacePersistence,
            toolPersistence: configuration.persistence.toolPersistence,
            workspaceProfile: configuration.runtime.workspaceProfile,
            workspaceCreator: configuration.runtime.workspaceCreator,
            customization: configuration.runtime.customization,
            runtimeToolPolicy: configuration.runtime.runtimeToolPolicy,
            diagnosticSnapshotConfiguration: configuration.runtime.diagnosticSnapshotConfiguration,
            degradationPolicy: configuration.runtime.degradationPolicy,
            generationParameters: configuration.generationParameters,
            toolApprovalPolicy: configuration.runtime.toolApprovalPolicy,
            loggingConfiguration: configuration.logging,
            sharedRegistry: ThreadPromptJournals(),
            additionalStages: []
        )
        if let warning = configuration.persistence.validateDurability().mixedDurabilityWarning {
            configuration.logging.logger(named: "positronickit-facade").warning(
                "\(configuration.logging.redactionPolicy.sanitizeStructured(warning))"
            )
        }
    }
}
