import Foundation
import PKAnthropicProvider
import PKContracts
import PKFoundationModelsProvider
import PKLocalEmbeddings
import PKObservable
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKPrompt
import PKTestSupport
import PositronicKit

// This target is intentionally small: its job is to prove that every public library
// product remains consumable through ordinary imports, without @testable access.
_ = String(describing: PositronicKit.self)
_ = String(describing: (any Prompt).self)
_ = String(describing: Message.self)
_ = String(describing: LocalEmbeddingService.self)
_ = String(describing: PKOpenAIProvider.self)
_ = String(describing: PKOpenRouterProvider.self)
_ = String(describing: PKOllamaProvider.self)
_ = String(describing: PKAnthropicProvider.self)
_ = String(describing: PKFoundationModelsProvider.self)
