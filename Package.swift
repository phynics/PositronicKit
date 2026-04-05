// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MonadCore", targets: ["MonadCore"]),
        .library(name: "MonadPrompt", targets: ["MonadPrompt"]),
        .library(name: "MonadShared", targets: ["MonadShared"]),
        .library(name: "MonadTestSupport", targets: ["MonadTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MonadShared",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MonadShared"
        ),
        .target(
            name: "MonadPrompt",
            dependencies: ["MonadShared"],
            path: "Sources/MonadPrompt"
        ),
        .target(
            name: "MonadCore",
            dependencies: [
                "MonadShared",
                "MonadPrompt",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "ErrorKit", package: "ErrorKit"),
            ],
            path: "Sources/MonadCore",
            exclude: ["README.md", "docs"]
        ),
        .target(
            name: "MonadTestSupport",
            dependencies: [
                "MonadCore",
                "MonadShared",
                "MonadPrompt",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Tests/MonadTestSupport"
        ),
        .testTarget(
            name: "MonadCoreTests",
            dependencies: [
                "MonadCore",
                "MonadShared",
                "MonadTestSupport",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Tests/MonadCoreTests"
        ),
        .testTarget(
            name: "MonadPromptTests",
            dependencies: ["MonadPrompt", "MonadTestSupport"],
            path: "Tests/MonadPromptTests"
        ),
        .testTarget(
            name: "MonadSharedTests",
            dependencies: ["MonadShared", "MonadTestSupport"],
            path: "Tests/MonadSharedTests"
        ),
    ]
)
