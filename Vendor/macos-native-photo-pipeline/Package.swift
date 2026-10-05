// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoPipeline",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PhotoPipeline", targets: ["PhotoPipeline"])
    ],
    targets: [
        .target(
            name: "PhotoPipeline",
            path: "Sources/PhotoPipeline",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreData"),
                .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SoundAnalysis"),
            ]
        ),
        .executableTarget(
            name: "SearchUI",
            dependencies: ["PhotoPipeline"],
            path: "Examples/search-ui"
        ),
        .testTarget(
            name: "PhotoPipelineTests",
            dependencies: ["PhotoPipeline"],
            path: "Tests/PhotoPipelineTests"
        )
    ]
)
