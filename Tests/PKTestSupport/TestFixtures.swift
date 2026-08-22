import Foundation
import PKContracts
import PKPrompt
import PKUtilities
import PositronicKit

    public extension Message {
        static func fixture(
            id: UUID = UUID(),
            role: MessageRole = .user,
            content: String = "Test message content",
            timestamp: Date = Date()
        ) -> Message {
            Message(id: id, timestamp: timestamp, content: content, role: role)
        }
    }

    public extension WorkspaceReference {
        static func fixture(
            id: UUID = UUID(),
            uri: WorkspaceURI = .threadWorkspace(UUID()),
            location: WorkspaceLocation = .runtime,
            originId: UUID? = nil,
            rootPath: String? = nil,
            tools: [ToolReference] = [],
            status: WorkspaceStatus = .active
        ) -> WorkspaceReference {
            WorkspaceReference(
                id: id,
                uri: uri,
                location: location,
                originID: originId,
                tools: tools,
                rootPath: rootPath,
                trustLevel: .full,
                status: status
            )
        }
    }

    public extension LLMConfiguration {
        /// Test-only convenience: builds a single-provider `LLMConfiguration` from flat
        /// arguments, replacing the removed public legacy flat initializer (PKV3-014). Fills in
        /// `activeProvider`'s `ProviderConfiguration` from `ProviderConfiguration.defaultFor(_:)`
        /// and overrides only the fields supplied here.
        static func fixture(
            endpoint: String? = nil,
            modelName: String? = nil,
            utilityModel: String? = nil,
            fastModel: String? = nil,
            apiKey: String? = nil,
            activeProvider: LLMProvider = .openAI,
            toolFormat: ToolCallFormat? = nil,
            memoryContextLimit: Int = 5,
            documentContextLimit: Int = 5,
            timeoutInterval: TimeInterval? = nil,
            maxRetries: Int? = nil,
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            topP: Double? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            applicationURL: String? = nil,
            applicationTitle: String? = nil
        ) -> LLMConfiguration {
            var providerConfig = ProviderConfiguration.makeDefault(for: activeProvider)
            if let endpoint { providerConfig.endpoint = endpoint }
            if let modelName { providerConfig.modelName = modelName }
            if let utilityModel { providerConfig.utilityModel = utilityModel }
            if let fastModel { providerConfig.fastModel = fastModel }
            if let apiKey { providerConfig.apiKey = apiKey }
            if let toolFormat { providerConfig.toolFormat = toolFormat }
            if let timeoutInterval { providerConfig.timeoutInterval = timeoutInterval }
            if let maxRetries { providerConfig.maxRetries = maxRetries }
            providerConfig.temperature = temperature
            providerConfig.maxTokens = maxTokens
            providerConfig.topP = topP
            providerConfig.frequencyPenalty = frequencyPenalty
            providerConfig.presencePenalty = presencePenalty
            providerConfig.seed = seed
            providerConfig.applicationURL = applicationURL
            providerConfig.applicationTitle = applicationTitle

            return LLMConfiguration(
                activeProvider: activeProvider,
                providers: [activeProvider: providerConfig],
                memoryContextLimit: memoryContextLimit,
                documentContextLimit: documentContextLimit
            )
        }
    }

    public extension RenderedPrompt.Section {
        /// Test-only convenience factory that fills in sensible defaults for every field
        /// except `id` and `content`, so tests don't have to spell out 11 parameters.
        static func fixture(
            id: String,
            content: PromptSection.Content,
            role: PromptSectionRole = .context,
            priority: Int = 50,
            estimatedTokens: Int = 10,
            compression: CompressionStrategy = .keep,
            type: PromptSectionType = .text,
            cachePolicy: CachePolicy = .stable,
            path: [String]? = nil,
            parentID: String? = nil
        ) -> RenderedPrompt.Section {
            RenderedPrompt.Section(
                id: id,
                role: role,
                priority: priority,
                estimatedTokens: estimatedTokens,
                compression: compression,
                type: type,
                cachePolicy: cachePolicy,
                path: path ?? ["root", id],
                parentID: parentID,
                content: content
            )
        }
    }
