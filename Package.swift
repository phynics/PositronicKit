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
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.4.8"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.11.2"),
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
            dependencies: ["PositronicKit"],
            path: "Sources/PKLocalEmbeddings"
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
                .product(name: "Dependencies", package: "swift-dependencies"),
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
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Tests/PositronicKitTests"
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
