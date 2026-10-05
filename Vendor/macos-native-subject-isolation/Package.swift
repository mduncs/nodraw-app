// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SubjectIsolation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SubjectIsolation", targets: ["SubjectIsolation"])
    ],
    targets: [
        .target(
            name: "SubjectIsolation",
            path: "Sources/SubjectIsolation",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "Demo",
            dependencies: ["SubjectIsolation"],
            path: "Examples/demo"
        ),
        .executableTarget(
            name: "DemoUI",
            dependencies: ["SubjectIsolation"],
            path: "Examples/demo-app"
        ),
        .testTarget(
            name: "SubjectIsolationTests",
            dependencies: ["SubjectIsolation"],
            path: "Tests/SubjectIsolationTests"
        )
    ]
)
