// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TabletDisplay",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "TabletDisplay",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/TabletDisplay",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        )
    ]
)
