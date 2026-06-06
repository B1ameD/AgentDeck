// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentDeck", targets: ["AgentDeckApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentDeckApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/AgentDeckApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AgentDeckTests",
            dependencies: ["AgentDeckApp"],
            path: "Tests/AgentDeckTests"
        )
    ]
)
