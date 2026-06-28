// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "llama-menubar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "llmctl",
            path: "Sources/llmctl",
            exclude: ["llama.png", "llama.icns"]
        )
    ]
)
