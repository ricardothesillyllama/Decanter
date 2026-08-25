// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Decanter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DecanterKit", targets: ["DecanterKit"]),
        .executable(name: "decanter", targets: ["decanter"]),
        .executable(name: "DecanterApp", targets: ["DecanterApp"]),
        .executable(name: "selftest", targets: ["selftest"]),
    ],
    targets: [
        // Engine. No external dependencies on purpose: every dependency is a
        // future 404. Whisky died because its runtime repo disappeared.
        .target(name: "DecanterKit"),
        .executableTarget(name: "decanter", dependencies: ["DecanterKit"]),
        .executableTarget(name: "DecanterApp", dependencies: ["DecanterKit"]),
        // Hand-rolled: XCTest ships with Xcode, not Command Line Tools, and
        // SwiftPM cannot see the CLT copy of Testing.framework. A plain
        // executable always runs.
        .executableTarget(name: "selftest", dependencies: ["DecanterKit"]),
    ]
)
