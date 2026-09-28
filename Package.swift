// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GazeVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet on the Neural Engine. Needs a Swift 6 toolchain to build.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "GazeVoice",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/GazeVoice"
        ),
    ]
)
