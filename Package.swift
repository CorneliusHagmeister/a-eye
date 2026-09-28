// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GazeVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GazeVoice", path: "Sources/GazeVoice"),
    ]
)
