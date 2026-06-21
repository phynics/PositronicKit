// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PositronicKit", targets: ["PositronicKit"]),
        .library(name: "PKPrompt", targets: ["PKPrompt"]),
        .library(name: "PKShared", targets: ["PKShared"]),
        .library(name: "PKLocalEmbeddings", targets: ["PKLocalEmbeddings"]),
        .library(name: "PKOpenAIProvider", targets: ["PKOpenAIProvider"]),
        .library(name: "PKOpenRouterProvider", targets: ["PKOpenRouterProvider"]),
        .library(name: "PKOllamaProvider", targets: ["PKOllamaProvider"]),
        .library(name: "PKTestSupport", targets: ["PKTestSupport"]),
        .executable(name: "PositronicKitExamples", targets: ["PositronicKitExamples"]),
    ],
    traits: [
        .trait(
            name: "MiniLMEmbeddings",
            description: "Build the in-process MiniLM embedding backend on Apple platforms."
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.4.8"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.11.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(path: "Packages/PKFastEmbed"),
    ],
    targets: [
        .target(
            name: "PKShared",
            dependencies: [
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PKShared"
        ),
        .target(
            name: "PKPrompt",
            dependencies: ["PKShared"],
            path: "Sources/PKPrompt"
        ),
        .target(
            name: "PositronicKit",
            dependencies: [
                "PKShared",
                "PKPrompt",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PositronicKit",
            exclude: ["README.md", "docs"]
        ),
        .target(
            name: "PKLocalEmbeddings",
            dependencies: [
                "PositronicKit",
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "PKMiniLMLinuxBackend", condition: .when(platforms: [.linux])),
                .target(name: "PKMiniLMTraitBackend", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Sources/PKLocalEmbeddings"
        ),
        .target(
            name: "PKMiniLMLinuxBackend",
            dependencies: [
                "PositronicKit",
                .product(name: "PKFastEmbed", package: "PKFastEmbed"),
            ],
            path: "Sources/PKMiniLMLinuxBackend"
        ),
        .target(
            name: "PKMiniLMTraitBackend",
            dependencies: [
                "PositronicKit",
                .product(
                    name: "PKFastEmbed",
                    package: "PKFastEmbed",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
            ],
            path: "Sources/PKMiniLMTraitBackend"
        ),
        .target(
            name: "PKOpenAIProvider",
            dependencies: [
                "PositronicKit",
                "PKPrompt",
                "PKShared",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenAIProvider"
        ),
        .target(
            name: "PKOpenRouterProvider",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenRouterProvider"
        ),
        .target(
            name: "PKOllamaProvider",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOllamaProvider"
        ),
        .executableTarget(
            name: "PositronicKitExamples",
            dependencies: [
                "PositronicKit",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PKPrompt",
                "PKShared",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PositronicKitExamples"
        ),
        .target(
            name: "PKTestSupport",
            dependencies: [
                "PositronicKit",
                "PKShared",
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
                "PositronicKitExamples",
                "PKShared",
                "PKTestSupport",
            ],
            path: "Tests/PositronicKitTests"
        ),
        .testTarget(
            name: "PKLocalEmbeddingsTests",
            dependencies: [
                "PKLocalEmbeddings",
                "PositronicKit",
                "PKShared",
                "PKTestSupport",
            ],
            path: "Tests/PKLocalEmbeddingsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PKPromptTests",
            dependencies: ["PKPrompt", "PKShared", "PKTestSupport"],
            path: "Tests/PKPromptTests"
        ),
        .testTarget(
            name: "PKSharedTests",
            dependencies: [
                "PKShared",
                "PKTestSupport",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKSharedTests"
        ),
    ]
)
