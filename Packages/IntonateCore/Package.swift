// swift-tools-version: 5.10
import PackageDescription

// Swift 5 mode with complete concurrency checking as warnings. The audio path synchronises through
// atomics the compiler cannot see, and CI's compiler is older than the one on the development
// machine, so a Swift 6 diagnostic difference must not be able to turn the build red.
let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "IntonateCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IntonateDSP", targets: ["IntonateDSP"]),
        .library(name: "IntonateSynth", targets: ["IntonateSynth"]),
        .library(name: "IntonateTraining", targets: ["IntonateTraining"]),
    ],
    targets: [
        .target(name: "CAtomicShim"),
        .target(name: "IntonateDSP", dependencies: ["CAtomicShim"], swiftSettings: strictConcurrency),
        .target(name: "IntonateSynth", dependencies: ["IntonateDSP"], swiftSettings: strictConcurrency),
        .target(
            name: "IntonateTraining",
            dependencies: ["IntonateDSP", "IntonateSynth"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "intonate-bench",
            dependencies: ["IntonateDSP", "IntonateSynth", "IntonateTraining"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(name: "IntonateDSPTests", dependencies: ["IntonateDSP", "IntonateSynth"]),
        .testTarget(
            name: "IntonateTrainingTests",
            dependencies: ["IntonateDSP", "IntonateSynth", "IntonateTraining"]
        ),
    ]
)
