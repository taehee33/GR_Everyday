// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GRLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GRLink", path: "Sources/GRLink")
    ]
)
