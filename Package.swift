// swift-tools-version: 6.0
import PackageDescription

// PorchKeep's logic lives in the PorchKeepKit library so it is linkable and
// unit-testable. The `PorchKeep` executable is a thin launcher; `PorchKeepTests`
// is a plain executable test runner built on a tiny in-repo harness — this
// machine has only the Command Line Tools, where neither XCTest nor Swift
// Testing resolves cleanly. Run the suite with `swift run PorchKeepTests`.

let package = Package(
    name: "PorchKeep",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PorchKeepKit",
            path: "Sources/PorchKeepKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Lets PorchKeepTests reach internal symbols via @testable.
                .unsafeFlags(["-enable-testing"])
            ]
        ),
        .executableTarget(
            name: "PorchKeep",
            dependencies: ["PorchKeepKit"],
            path: "Sources/PorchKeep",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PorchKeepTests",
            dependencies: ["PorchKeepKit"],
            path: "Tests/PorchKeepTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
