// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmbientDisplay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AmbientDisplay",
            targets: ["AmbientDisplay"]
        ),
        .library(
            name: "AmbientDisplayCore",
            targets: ["AmbientDisplayCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0")
    ],
    targets: [
        .target(
            name: "AmbientDisplayCore",
            dependencies: [
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk")
            ],
            path: "Sources/AmbientDisplayCore",
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
            name: "AmbientDisplay",
            dependencies: ["AmbientDisplayCore"],
            path: "Sources/AmbientDisplay"
        ),
        .executableTarget(
            name: "RenderSnapshots",
            dependencies: ["AmbientDisplayCore"],
            path: "Sources/RenderSnapshots"
        ),
        .testTarget(
            name: "AmbientDisplayTests",
            dependencies: ["AmbientDisplayCore"],
            path: "Tests/AmbientDisplayTests"
        )
    ]
)
