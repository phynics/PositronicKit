import Foundation
import PKContracts
import PKUtilities
import PositronicKit

    /// Explicit test composition root for PositronicKit runtime tests.
    ///
    /// `TestRuntime` replaces the former ambient dependency-injection machinery with plain
    /// constructor injection: every store and service is wired from a single
    /// `MockPersistenceService` so a test can rely on one coherent, shared persistence backing.
    ///
    /// Construct one per test with a unique `workspaceRoot`, then read its fields directly or
    /// access `positronicKit` for a fully-wired facade. Consumer-facing tests should use the
    /// facade's capability values rather than concrete coordinators.
    public struct TestRuntime: Sendable {
        public let persistence: MockPersistenceService
        public let llm: MockLLMService

        private let core: PositronicKit

        public var threads: ThreadCapability { core.threads }
        public var agents: AgentCapability { core.agents }
        public var workspaces: WorkspaceCapability { core.workspaces }

        public var threadPersistence: any ThreadPersistenceProtocol {
            persistence
        }

        /// Creates a fully-wired runtime. All collaborators default to values built from the
        /// supplied `persistence`, so the whole graph shares one backing store. The
        /// `PositronicKit` facade is the sole place that builds its internal coordinators;
        /// the capability values above are the test-facing consumer surface.
        ///
        /// - Parameters:
        ///   - workspaceRoot: Unique root directory for this runtime's workspaces.
        ///   - persistence: Backing store shared by every collaborator. Defaults to a fresh mock.
        ///   - llm: Mock LLM service. Defaults to a fresh mock.
        ///   - workspaceCreator: Workspace factory for the thread manager. Defaults to `MockWorkspaceCreator`.
        public init(
            workspaceRoot: URL,
            persistence: MockPersistenceService = MockPersistenceService(),
            llm: MockLLMService = MockLLMService(),
            workspaceCreator: any WorkspaceFactory = MockWorkspaceCreator()
        ) {
            self.persistence = persistence
            self.llm = llm

            core = PositronicKit(configuration: .init(provider: .init(languageModel: llm), persistence: .init(
                    runtimeRepository: persistence,
                    workspacePersistence: persistence,
                    toolPersistence: persistence,
                    agentStore: persistence,
                    requestOriginStore: persistence
                ), runtime: .init(
                    workspaceProfile: .hostManaged(root: workspaceRoot),
                    workspaceCreator: workspaceCreator
                )))

        }

        /// The `PositronicKit` facade wired to this runtime's stores, managers, and services.
        public var positronicKit: PositronicKit {
            core
        }

        /// Returns the `PositronicKit` facade wired to this runtime.
    }
