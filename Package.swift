// swift-tools-version: 5.9
import PackageDescription

// Build contract for the OpenCode Go limits monitor.
// No remote packages: only system frameworks (Foundation, SystemConfiguration,
// Security, SQLite3, SwiftUI, Charts, UserNotifications, ServiceManagement).
let package = Package(
    name: "OpenCodeLimits",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3"),
        .target(
            name: "OpenCodeLimitsCore",
            dependencies: ["CSQLite3"],
            path: "Sources/OpenCodeLimitsCore"
        ),
        .executableTarget(
            name: "OpenCodeLimits",
            dependencies: ["OpenCodeLimitsCore"],
            path: "Sources/OpenCodeLimits"
        ),
        // The machine has CommandLineTools only: XCTest.framework / XCTest.swiftmodule
        // are absent, so `swift test` cannot resolve `import XCTest`. Tests are a
        // dependency-free executable runner instead (`make test` / `make smoke`).
        .executableTarget(
            name: "OpenCodeLimitsTests",
            dependencies: ["OpenCodeLimitsCore"],
            path: "Tests/OpenCodeLimitsTests"
        ),
    ]
)
