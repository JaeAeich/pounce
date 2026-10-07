// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pounce",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: matching, labels, config, mode state machines. No AppKit.
        .target(
            name: "PounceCore",
            path: "Sources/PounceCore"
        ),
        .executableTarget(
            name: "Pounce",
            dependencies: ["PounceCore"],
            path: "Sources/Pounce",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PounceCoreTests",
            dependencies: ["PounceCore"],
            path: "Tests/PounceCoreTests"
        ),
    ]
)
