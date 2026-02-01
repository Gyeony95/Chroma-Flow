// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromaFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "ChromaFlow",
            targets: ["ChromaFlow"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ChromaFlow",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                "DDCKit"
            ],
            path: "ChromaFlow",
            exclude: [
                "ChromaFlow.entitlements",
                "Resources/Info.plist",
                "Assets.xcassets.backup",
                "HardwareBridge/SOLAR_SCHEDULE_README.md"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Localizable.xcstrings")
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .target(
            name: "DDCKit",
            path: "Packages/DDCKit/Sources/DDCKit"
        )
    ]
)
