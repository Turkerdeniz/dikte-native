// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DikteNative",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DikteNative", targets: ["DikteNative"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .executableTarget(
            name: "DikteNative",
            dependencies: ["whisper"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "DikteNativeTests",
            dependencies: ["DikteNative"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
