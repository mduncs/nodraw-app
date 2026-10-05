// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DataTable",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DataTable", targets: ["DataTable"]),
    ],
    targets: [
        .target(name: "DataTable"),
    ]
)
