// swift-tools-version: 6.0
import PackageDescription

let privateFrameworks: [LinkerSetting] = [
    .unsafeFlags(["-F/System/Library/PrivateFrameworks"]),
    .linkedFramework("SkyLight"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("ApplicationServices"),
]

let package = Package(
    name: "snappyborders",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "snappyborders", targets: ["SnappyBorders"]),
    ],
    targets: [
        .target(name: "CSkyLight"),
        .executableTarget(
            name: "SnappyBorders",
            dependencies: ["CSkyLight"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: privateFrameworks
        ),
        .executableTarget(
            name: "sbprobe",
            dependencies: ["CSkyLight"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: privateFrameworks
        ),
    ]
)
