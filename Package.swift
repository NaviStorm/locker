// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LockerCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LockerCore", targets: ["LockerCore"])],
    targets: [
        .target(name: "LockerCore", path: "Core"),
        .testTarget(name: "LockerCoreTests", dependencies: ["LockerCore"], path: "Tests")
    ]
)
