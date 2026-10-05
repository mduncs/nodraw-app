// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NoDraw",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NoDraw", targets: ["MediaViewer"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(path: "Vendor/macos-native-subject-isolation"),
        .package(path: "Vendor/macos-native-photo-pipeline"),
        .package(path: "Vendor/DataTable")
    ],
    targets: [
        .executableTarget(
            name: "MediaViewer",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SubjectIsolation", package: "macos-native-subject-isolation"),
                .product(name: "PhotoPipeline", package: "macos-native-photo-pipeline"),
                .product(name: "DataTable", package: "DataTable")
            ],
            path: "Sources/MediaViewer",
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "MediaViewerTests",
            dependencies: ["MediaViewer"],
            path: "Tests/MediaViewerTests"
        ),
        .testTarget(
            name: "AnnotationEditorTests",
            dependencies: [
                "MediaViewer",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/AnnotationEditorTests",
            exclude: ["Fixtures"]
        )
    ]
)
