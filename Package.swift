// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "luna",
    platforms: [.macOS(.v10_15)],
    targets: [
        // Objective-C declarations for the private CoreGraphics virtual display API
        .target(
            name: "CVD",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // Shared wire protocol and identifiers between sender and receiver
        .target(
            name: "LunaProto",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        // Shared VideoToolbox H.264 encoder
        .target(
            name: "LunaMedia",
            dependencies: ["LunaProto"],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "LunaSender",
            dependencies: ["CVD", "LunaProto", "LunaMedia"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "LunaReceiver",
            dependencies: ["LunaProto", "LunaMedia"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "LunaProtoTests", dependencies: ["LunaProto"]),
    ]
)
