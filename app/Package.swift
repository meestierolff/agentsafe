// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSafe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentSafeCore", targets: ["AgentSafeCore"]),
        .executable(name: "AgentSafe", targets: ["AgentSafe"]),
        .executable(name: "agentsafe-cli", targets: ["agentsafe-cli"]),
    ],
    targets: [
        // All logic that can be tested without a screen or a fingerprint lives here.
        .target(name: "AgentSafeCore"),
        .executableTarget(name: "AgentSafe", dependencies: ["AgentSafeCore"]),
        // The `agentsafe` command. Built as "agentsafe-cli" because the app's own binary is
        // "AgentSafe" and macOS file names ignore case; it is renamed when copied into the app.
        .executableTarget(name: "agentsafe-cli", dependencies: ["AgentSafeCore"], path: "Sources/AgentSafeCLI"),
        .testTarget(name: "AgentSafeCoreTests", dependencies: ["AgentSafeCore", "agentsafe-cli"]),
    ]
)
