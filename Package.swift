// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LockerCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LockerCore", targets: ["LockerCore"])],
    targets: [
        .systemLibrary(name: "CLockerArchive", path: "Modules/CLockerArchive"),
        .target(name: "LockerCore", dependencies: ["CLockerArchive"], path: "Core"),
        .testTarget(name: "LockerCoreTests", dependencies: ["LockerCore"], path: "Tests")
    ]
)
