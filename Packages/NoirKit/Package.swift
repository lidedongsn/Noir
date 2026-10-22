// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoirKit",
    platforms: [.macOS(.v15), .tvOS(.v18), .iOS(.v18)],
    products: [
        .library(name: "NoirEngine", targets: ["NoirEngine"]),
    ],
    targets: [
        // 精简 FFmpeg：由 scripts/build-ffmpeg.sh 生成，模块名 CFFmpeg
        .binaryTarget(name: "FFmpeg", path: "Frameworks/FFmpeg.xcframework"),
        .target(
            name: "NoirEngine",
            dependencies: ["FFmpeg"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "NoirEngineTests",
            dependencies: ["NoirEngine"]
        ),
    ]
)
