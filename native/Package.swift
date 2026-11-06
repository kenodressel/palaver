// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "palaver-engine",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "vendor/FluidAudio")],
    targets: [
        // The speech engine (phase 1).
        .target(name: "PalaverEngine",
                dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                swiftSettings: v5),
        .executableTarget(name: "palaver-engine", dependencies: ["PalaverEngine"], swiftSettings: v5),
        .testTarget(name: "PalaverEngineTests", dependencies: ["PalaverEngine"], swiftSettings: v5),
        // The app (phase 2). PalaverCore has no AppKit: pure logic, testable anywhere.
        .target(name: "PalaverCore", swiftSettings: v5),
        .target(name: "PalaverDaemon", dependencies: ["PalaverCore", "PalaverCapture"], swiftSettings: v5),
        .target(name: "PalaverCapture", dependencies: ["PalaverCore"], swiftSettings: v5),
        .executableTarget(name: "Palaver",
                          dependencies: ["PalaverCore", "PalaverDaemon", "PalaverCapture"],
                          resources: [.copy("Resources/menubar.png")],  // the template icon (black: macOS tints it)
                          swiftSettings: v5),
        // Test-only: binds the notify socket with a recording fake center (tests/test_notify_swift_contract.py).
        .executableTarget(name: "palaver-notify-helper", dependencies: ["PalaverCore"], swiftSettings: v5),
        // Test-only: serves app.sock with fake handlers (tests/test_appctl_swift_contract.py).
        .executableTarget(name: "palaver-appctl-helper", dependencies: ["PalaverCore", "PalaverDaemon"], swiftSettings: v5),
        .testTarget(name: "PalaverDaemonTests", dependencies: ["PalaverCore", "PalaverDaemon", "PalaverCapture"], swiftSettings: v5),
        .testTarget(name: "PalaverCoreTests", dependencies: ["PalaverCore"], swiftSettings: v5),
        .testTarget(name: "PalaverCaptureTests", dependencies: ["PalaverCapture", "PalaverCore"], swiftSettings: v5),
    ]
)
