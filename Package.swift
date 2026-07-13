// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PositronicKit", targets: ["PositronicKit"]),
        .library(name: "PKObservable", targets: ["PKObservable"]),
        .library(name: "PKPrompt", targets: ["PKPrompt"]),
        .library(name: "PKShared", targets: ["PKShared"]),
        .library(name: "PKUtilities", targets: ["PKUtilities"]),
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
            name: "PKShared",
            dependencies: [
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PKShared"
        ),
        .target(
            name: "PKPrompt",
            dependencies: ["PKShared", "PKUtilities"],
            path: "Sources/PKPrompt"
        ),
        .target(
            name: "PKUtilities",
            dependencies: [
                "PKShared",
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PKUtilities"
        ),
        .target(
            name: "PositronicKit",
            dependencies: [
                "PKShared",
                "PKPrompt",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
            ],
            path: "Sources/PositronicKit"
        ),
        .target(
            name: "PKObservable",
            dependencies: ["PositronicKit"],
            path: "Sources/PKObservable"
        ),
        .target(
            name: "PKLocalEmbeddings",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "PKFastEmbed", condition: .when(platforms: [.linux])),
                .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Sources/PKLocalEmbeddings"
        ),
        .systemLibrary(
            name: "CPKFastEmbed",
            path: "Sources/CPKFastEmbed",
            pkgConfig: "pkfastembed"
        ),
        .target(
            name: "PKFastEmbed",
            dependencies: ["CPKFastEmbed", "PKShared", "PKUtilities", "PositronicKit"],
            path: "Sources/PKFastEmbed"
        ),
        .target(
            name: "PKOpenAIProvider",
            dependencies: [
                "PKShared",
                "PKUtilities",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenAIProvider"
        ),
        .target(
            name: "PKOpenRouterProvider",
            dependencies: [
                "PKShared",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenRouterProvider"
        ),
        .target(
            name: "PKOllamaProvider",
            dependencies: [
                "PKShared",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOllamaProvider"
        ),
        .target(
            name: "PKAnthropicProvider",
            dependencies: [
                "PKShared",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKAnthropicProvider"
        ),
        .target(
            name: "PKFoundationModelsProvider",
            dependencies: [
                "PKShared",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKFoundationModelsProvider"
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
                "PKShared",
                "PKUtilities",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PositronicKitExamples"
        ),
        .target(
            name: "PKTestSupport",
            dependencies: [
                "PositronicKit",
                "PKShared",
                "PKUtilities",
                "PKPrompt",
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            path: "Tests/PKTestSupport"
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
                "PKShared",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Tests/PositronicKitTests"
        ),
        .testTarget(
            name: "PKObservableTests",
            dependencies: ["PKObservable", "PKTestSupport"],
            path: "Tests/PKObservableTests"
        ),
        .testTarget(
            name: "PKLocalEmbeddingsTests",
            dependencies: [
                "PKLocalEmbeddings",
                "PositronicKit",
                "PKShared",
                "PKUtilities",
                "PKTestSupport",
            ],
            path: "Tests/PKLocalEmbeddingsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PKFastEmbedTests",
            dependencies: [
                .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Tests/PKFastEmbedTests"
        ),
        .testTarget(
            name: "PKPromptTests",
            dependencies: ["PKPrompt", "PKShared", "PKUtilities", "PKTestSupport"],
            path: "Tests/PKPromptTests"
        ),
        .testTarget(
            name: "PKSharedTests",
            dependencies: [
                "PKShared",
                "PKUtilities",
                "PKTestSupport",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKSharedTests"
        ),
        .testTarget(
            name: "PKUtilitiesTests",
            dependencies: ["PKUtilities", "PKShared", "PKTestSupport"],
            path: "Tests/PKUtilitiesTests"
        ),
        .testTarget(
            name: "PKOpenAIProviderTests",
            dependencies: [
                "PKOpenAIProvider",
                "PKShared",
                "PKUtilities",
                "PositronicKit",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOpenAIProviderTests"
        ),
        .testTarget(
            name: "PKOpenRouterProviderTests",
            dependencies: [
                "PKOpenRouterProvider",
                "PKShared",
                "PKUtilities",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOpenRouterProviderTests"
        ),
        .testTarget(
            name: "PKOllamaProviderTests",
            dependencies: [
                "PKOllamaProvider",
                "PKShared",
                "PKUtilities",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKOllamaProviderTests"
        ),
        .testTarget(
            name: "PKAnthropicProviderTests",
            dependencies: [
                "PKAnthropicProvider",
                "PKShared",
                "PKUtilities",
                "PKTestSupport",
                "PositronicKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PKAnthropicProviderTests"
        ),
        .testTarget(
            name: "PKFoundationModelsProviderTests",
            dependencies: [
                "PKFoundationModelsProvider",
                "PKShared",
                "PKUtilities",
                "PKTestSupport",
                "PositronicKit",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKFoundationModelsProviderTests"
        ),
        .testTarget(
            name: "PKTestSupportTests",
            dependencies: [
                "PKTestSupport",
                "PKShared",
                "PKUtilities",
            ],
            path: "Tests/PKTestSupportTests"
        ),
    ]
)
