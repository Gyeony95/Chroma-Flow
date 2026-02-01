// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DDCKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DDCKit", targets: ["DDCKit"])
    ],
    targets: [
        .target(name: "DDCKit"),
        .testTarget(name: "DDCKitTests", dependencies: ["DDCKit"])
    ]
)
