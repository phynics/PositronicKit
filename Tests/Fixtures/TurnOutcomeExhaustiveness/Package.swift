// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TurnOutcomeExhaustiveness",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(name: "PositronicKit", path: "../../../")],
    targets: [
        .executableTarget(
            name: "TurnOutcomeExhaustiveness",
            dependencies: [.product(name: "PositronicKit", package: "PositronicKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
