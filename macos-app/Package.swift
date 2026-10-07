// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WakeMeUp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "WakeMeUp",
            targets: ["WakeMeUp"]
        ),
        .library(
            name: "WakeMeUpCore",
            targets: ["WakeMeUpCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WakeMeUpCore",
            dependencies: [],
            path: "Sources/WakeMeUpCore",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "WakeMeUp",
            dependencies: ["WakeMeUpCore"],
            path: "Sources/WakeMeUp"
        ),
        .executableTarget(
            name: "RenderSnapshots",
            dependencies: ["WakeMeUpCore"],
            path: "Sources/RenderSnapshots"
        ),
        .testTarget(
            name: "WakeMeUpTests",
            dependencies: ["WakeMeUpCore"],
            path: "Tests/WakeMeUpTests"
        )
    ]
)
