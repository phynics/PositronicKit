// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TurnOutcomeExhaustiveness",
    dependencies: [.package(path: "../../../")],
    targets: [
        .executableTarget(
            name: "TurnOutcomeExhaustiveness",
            dependencies: [.product(name: "PositronicKit", package: "workspace")]
        )
    ],
    swiftLanguageModes: [.v6]
)
