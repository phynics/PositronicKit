// swift-tools-version: 6.2
import PackageDescription

// Enforce the concurrency gate required by the reference-box elimination handoff.
// In the Swift 6 language mode (default for this tools version) complete strict
// concurrency checking is already on; Approachable Concurrency (SE-0461 + SE-0470)
// adds the two behaviors that mode does not already imply: nonisolated async
// functions run on the caller's actor, and global-actor-isolated types get
// actor-scoped protocol conformances. Applied to every source, test, example, and
// fixture target so the gate cannot be bypassed.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

#if os(Linux)
let pkFastEmbedDependency: Target.Dependency = .target(
    name: "PKFastEmbed",
    condition: .when(platforms: [.linux])
)
let cpkFastEmbedTarget: Target = .systemLibrary(
    name: "CPKFastEmbed",
    path: "Sources/CPKFastEmbed",
    pkgConfig: "pkfastembed"
)
#else
let pkFastEmbedDependency: Target.Dependency = .target(
    name: "PKFastEmbed",
    condition: .when(traits: ["MiniLMEmbeddings"])
)
// Apple builds use the bridge only when the MiniLM trait is enabled. Avoid
// probing pkg-config during ordinary builds, where no native prefix is needed.
let cpkFastEmbedTarget: Target = .systemLibrary(
    name: "CPKFastEmbed",
    path: "Sources/CPKFastEmbed"
)
#endif

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "PositronicKit", targets: ["PositronicKit"]),
        .library(name: "PKObservable", targets: ["PKObservable"]),
        .library(name: "PKPrompt", targets: ["PKPrompt"]),
        .library(name: "PKContracts", targets: ["PKContracts"]),
        .library(name: "PKLocalEmbeddings", targets: ["PKLocalEmbeddings"]),
        .library(name: "PKOpenAIProvider", targets: ["PKOpenAIProvider"]),
        .library(name: "PKOpenRouterProvider", targets: ["PKOpenRouterProvider"]),
        .library(name: "PKOllamaProvider", targets: ["PKOllamaProvider"]),
        .library(name: "PKAnthropicProvider", targets: ["PKAnthropicProvider"]),
        .library(name: "PKFoundationModelsProvider", targets: ["PKFoundationModelsProvider"]),
        .library(name: "PKTestSupport", targets: ["PKTestSupport"]),
        .executable(name: "PositronicKitExamples", targets: ["PositronicKitExamples"]),
    ],
    traits: [
        .trait(
            name: "MiniLMEmbeddings",
            description: "Build the in-process MiniLM embedding backend on Apple platforms."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.4.8"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.11.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/itruf/PartialJSON.git", exact: "0.0.2"),
    ],
    targets: [
        .target(
            name: "PKContracts",
            dependencies: [
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PKContracts",
            exclude: ["CONTEXT.md"],
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKPrompt",
            dependencies: ["PKContracts", "PKUtilities"],
            path: "Sources/PKPrompt",
            exclude: ["CONTEXT.md"],
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKUtilities",
            dependencies: [
                "PKContracts",
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PKUtilities",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PositronicKit",
            dependencies: [
                "PKContracts",
                "PKPrompt",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
            ],
            path: "Sources/PositronicKit",
            exclude: ["PositronicKit.docc", "CONTEXT.md"],
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKObservable",
            dependencies: ["PositronicKit"],
            path: "Sources/PKObservable",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKLocalEmbeddings",
            dependencies: [
                "PKContracts",
                .product(name: "Crypto", package: "swift-crypto"),
                pkFastEmbedDependency,
            ],
            path: "Sources/PKLocalEmbeddings",
            swiftSettings: approachableConcurrency
        ),
        cpkFastEmbedTarget,
        .target(
            name: "PKFastEmbed",
            dependencies: ["CPKFastEmbed", "PKContracts"],
            path: "Sources/PKFastEmbed",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKOpenAIProvider",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenAIProvider",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKOpenRouterProvider",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenRouterProvider",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKOllamaProvider",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOllamaProvider",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKAnthropicProvider",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKAnthropicProvider",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKFoundationModelsProvider",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKFoundationModelsProvider",
            swiftSettings: approachableConcurrency
        ),
        .executableTarget(
            name: "PositronicKitExamples",
            dependencies: [
                "PositronicKit",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PKAnthropicProvider",
                "PKFoundationModelsProvider",
                "PKPrompt",
                "PKContracts",
                "PKUtilities",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PositronicKitExamples",
            swiftSettings: approachableConcurrency
        ),
        .executableTarget(
            name: "PKPromptJournalProcessFixture",
            dependencies: ["PKPrompt"],
            path: "Tests/PKPromptJournalProcessFixture",
            swiftSettings: approachableConcurrency
        ),
        .executableTarget(
            name: "PublicProductConsumer",
            dependencies: [
                "PositronicKit",
                "PKObservable",
                "PKPrompt",
                "PKContracts",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PKAnthropicProvider",
                "PKFoundationModelsProvider",
                "PKTestSupport",
            ],
            path: "Tests/PublicProductConsumer",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "PKTestSupport",
            dependencies: [
                "PositronicKit",
                "PKContracts",
                "PKUtilities",
                "PKPrompt",
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            path: "Tests/PKTestSupport",
            swiftSettings: approachableConcurrency
        ),
        .executableTarget(
            name: "PKTestSupportConsumer",
            dependencies: ["PKTestSupport", "PKContracts", "PositronicKit"],
            path: "Tests/PKTestSupportConsumer",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PositronicKitTests",
            dependencies: [
                "PositronicKit",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PKAnthropicProvider",
                // Kept intentionally: Tests/PositronicKitTests/Stories/Examples/*.swift
                // exercises PKPromptExamples/PositronicKitUsageExamples directly (not a
                // trivial compile check) so the living-documentation examples stay
                // behaviorally correct, not just compiling. Removing this dependency
                // would drop that coverage rather than relocate it.
                "PositronicKitExamples",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Tests/PositronicKitTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKObservableTests",
            dependencies: ["PKObservable", "PKTestSupport"],
            path: "Tests/PKObservableTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKLocalEmbeddingsTests",
            dependencies: [
                "PKLocalEmbeddings",
                "PositronicKit",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
            ],
            path: "Tests/PKLocalEmbeddingsTests",
            resources: [.copy("Fixtures")],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKFastEmbedTests",
            dependencies: [
                .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Tests/PKFastEmbedTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKPromptTests",
            dependencies: ["PKPrompt", "PKContracts", "PKUtilities", "PKTestSupport"],
            path: "Tests/PKPromptTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKContractsTests",
            dependencies: [
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKContractsTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKUtilitiesTests",
            dependencies: ["PKUtilities", "PKContracts", "PKTestSupport"],
            path: "Tests/PKUtilitiesTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKOpenAIProviderTests",
            dependencies: [
                "PKOpenAIProvider",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                "PositronicKit",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOpenAIProviderTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKOpenRouterProviderTests",
            dependencies: [
                "PKOpenRouterProvider",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOpenRouterProviderTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKOllamaProviderTests",
            dependencies: [
                "PKOllamaProvider",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOllamaProviderTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKAnthropicProviderTests",
            dependencies: [
                "PKAnthropicProvider",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                "PositronicKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKAnthropicProviderTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKFoundationModelsProviderTests",
            dependencies: [
                "PKFoundationModelsProvider",
                "PKContracts",
                "PKUtilities",
                "PKTestSupport",
                "PositronicKit",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKFoundationModelsProviderTests",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "PKTestSupportTests",
            dependencies: [
                "PKTestSupport",
                "PKContracts",
                "PKUtilities",
            ],
            path: "Tests/PKTestSupportTests",
            swiftSettings: approachableConcurrency
        ),
    ]
)
