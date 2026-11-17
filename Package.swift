// swift-tools-version:5.9
//
// Digby Video Compressor
//
//   DigbyCore  – UI-independent engine: probing, content analysis, planning,
//                encoder back-ends, target-size optimisation, VMAF.
//   DigbyApp   – the SwiftUI macOS application.
//   digby        – command-line driver for the engine (used by the test suite
//                and handy for scripting).
//   digby-tests – unit tests for the pure planning logic.
//
import PackageDescription

let package = Package(
    name: "DigbyVideoCompressor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DigbyApp", targets: ["DigbyApp"]),
        .executable(name: "digby", targets: ["digby"]),
        .library(name: "DigbyCore", targets: ["DigbyCore"]),
    ],
    targets: [
        .target(name: "DigbyCore", path: "Sources/DigbyCore"),
        .executableTarget(name: "DigbyApp", dependencies: ["DigbyCore"], path: "Sources/DigbyApp"),
        .executableTarget(name: "digby", dependencies: ["DigbyCore"], path: "Sources/digby"),
        // Unit tests as a plain executable (`swift run digby-tests`): works with Command Line
        // Tools alone, which ship neither XCTest nor a SwiftPM-visible Testing module.
        .executableTarget(name: "digby-tests", dependencies: ["DigbyCore"], path: "Sources/digby-tests"),
    ]
)
