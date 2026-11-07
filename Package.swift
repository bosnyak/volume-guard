// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VolumeGuard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VolumeGuard", targets: ["VolumeGuard"])
    ],
    targets: [
        .executableTarget(
            name: "VolumeGuard",
            path: "Sources/VolumeGuard",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security")
            ]
        )
    ]
)
