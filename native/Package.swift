// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

/// The echo canceller's prebuilt archives (native/Vendored/webrtc_aec/lib, beside this file).
let packageDir = String(#filePath.dropLast("Package.swift".count))
let aecDir = packageDir + "Vendored/webrtc_aec/lib/"

let package = Package(
    name: "palaver-engine",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "vendor/FluidAudio"),
                   // The window's HTTP server (phase 3): pinned, recorded in the phase-3 ledger.
                   .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
                   // The local language model (phase 4, PalaverMLX only): MLX, its models and the tokenizers, pinned.
                   .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
                   .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
                   .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5")],
    targets: [
        // The speech engine (phase 1).
        .target(name: "PalaverEngine",
                dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                swiftSettings: v5),
        .executableTarget(name: "palaver-engine", dependencies: ["PalaverEngine"], swiftSettings: v5),
        .testTarget(name: "PalaverEngineTests", dependencies: ["PalaverEngine"], swiftSettings: v5),
        // The app (phase 2). PalaverCore has no AppKit: pure logic, testable anywhere.
        .target(name: "PalaverCore", swiftSettings: v5),
        .target(name: "PalaverDaemon", dependencies: ["PalaverCore", "PalaverDomain", "PalaverCapture", "PalaverCloud"],
                swiftSettings: v5),
        .target(name: "PalaverCapture", dependencies: ["PalaverCore"], swiftSettings: v5),
        .executableTarget(name: "Palaver",
                          dependencies: ["PalaverCore", "PalaverDaemon", "PalaverCapture", "PalaverCloud"],
                          resources: [.copy("Resources/menubar.png")],  // the template icon (black: macOS tints it)
                          swiftSettings: v5),
        // tools/smoke_install.sh's driver of an installed app's Swift updater (never in Palaver.app).
        .executableTarget(name: "palaver-update-driver", dependencies: ["PalaverCore", "PalaverDaemon", "PalaverDomain"],
                          swiftSettings: v5),
        .testTarget(name: "PalaverDaemonTests", dependencies: ["PalaverCore", "PalaverDomain", "PalaverDaemon", "PalaverCapture", "PalaverCloud"],
                    swiftSettings: v5),
        .testTarget(name: "PalaverCoreTests", dependencies: ["PalaverCore"], swiftSettings: v5),
        .testTarget(name: "PalaverCaptureTests", dependencies: ["PalaverCapture", "PalaverCore"], swiftSettings: v5),
        // Vendored C libraries for Ogg Opus audio (Sources/COgg, Sources/COpus: see their VERSION files).
        .target(name: "COgg", path: "Sources/COgg", publicHeadersPath: "include"),
        .target(name: "COpus", path: "Sources/COpus", publicHeadersPath: "include",
                cSettings: [.define("HAVE_CONFIG_H"), .define("OPUS_WILL_BE_SLOW", .when(configuration: .debug)),
                            .headerSearchPath("."), .headerSearchPath("celt"),
                            .headerSearchPath("silk"), .headerSearchPath("silk/float")]),
        // The server's domain (phase 3): every file format and rule of the meetings, no AppKit, no NIO.
        .target(name: "PalaverDomain", dependencies: ["PalaverCore", "COgg", "COpus"], resources: [.copy("Resources")], swiftSettings: v5),
        .testTarget(name: "PalaverDomainTests", dependencies: ["PalaverDomain", "PalaverCore", "COgg", "COpus"],
                    resources: [.copy("Goldens")], swiftSettings: v5),
        // Phase 4: the Keychain, the providers, the HTTP transport and the access log (no MLX). The legacy Keychain
        // ACL calls (deprecated, still the only way to trust several executables) sit in a small C shim.
        .target(name: "CKeychainACL", path: "Sources/CKeychainACL", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "PalaverCloud", dependencies: ["PalaverDomain", "PalaverCore", "CKeychainACL"], swiftSettings: v5),
        .testTarget(name: "PalaverCloudTests", dependencies: ["PalaverCloud", "PalaverDomain", "PalaverCore"], swiftSettings: v5),
        // The window's server (phase 3): `palaver-server`, the port of `palaver webapp-serve`.
        .target(name: "PalaverServer",
                dependencies: ["PalaverDomain", "PalaverCloud",
                               .product(name: "NIOCore", package: "swift-nio"),
                               .product(name: "NIOPosix", package: "swift-nio"),
                               .product(name: "NIOHTTP1", package: "swift-nio")],
                swiftSettings: v5),
        .executableTarget(name: "palaver-server", dependencies: ["PalaverServer"], swiftSettings: v5),
        // The `palaver` command (phase 4; bin/palaver in the bundle): `palaver mcp`, Claude's tools over stdio.
        .executableTarget(name: "palaver-cli", dependencies: ["PalaverServer"], swiftSettings: v5),
        .testTarget(name: "PalaverServerTests", dependencies: ["PalaverServer", "PalaverDomain", "PalaverCore", "PalaverCloud"],
                    swiftSettings: v5),
        // The pipeline's worker (phase 3): `palaver-worker <cmd> …`, the port of `palaver process|run|live|stream|coach|
        // index`, `calendar attach` and `app query`; the speech engine runs in its process.
        // WebRTC echo cancellation (libraven_aec): the prebuilt archives force-loaded, the header in place.
        .target(name: "CRavenAEC", path: "Sources/CRavenAEC",
                linkerSettings: [.unsafeFlags(["-Xlinker", "-force_load", "-Xlinker", aecDir + "Darwin/libraven_aec.a",
                                               aecDir + "macos/libwebrtc_audio_processing.a", aecDir + "macos/libcommon_audio.a",
                                               aecDir + "macos/libsystem_wrappers.a", aecDir + "macos/libwebrtc.a"]),
                                 .linkedFramework("Accelerate"), .linkedFramework("AudioToolbox"),
                                 .linkedFramework("CoreAudio"), .linkedLibrary("c++")]),
        .target(name: "PalaverWorker", dependencies: ["PalaverDomain", "PalaverEngine", "PalaverCloud", "CRavenAEC"], swiftSettings: v5),
        .executableTarget(name: "palaver-worker", dependencies: ["PalaverWorker"], swiftSettings: v5),
        // Phase 4: the language model's features (notes, projects, the best next question) with the cloud and Claude CLI
        // runners, and `palaver-lm`, the worker that runs them (the local MLX runner joins in PalaverMLX).
        .target(name: "PalaverLM", dependencies: ["PalaverCloud", "PalaverDomain", "PalaverCore"], swiftSettings: v5),
        // The local model on MLX (Gemma through mlx-swift-lm). Only palaver-lm links it; its Metal shaders are built by
        // xcodebuild (`make lm`), a `swift build` of palaver-lm runs every model but the local one.
        .target(name: "PalaverMLX",
                dependencies: ["PalaverLM", "PalaverDomain", "PalaverCore",
                               .product(name: "MLX", package: "mlx-swift"),
                               .product(name: "MLXLLM", package: "mlx-swift-lm"),
                               .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                               .product(name: "Tokenizers", package: "swift-transformers")],
                swiftSettings: v5),
        .executableTarget(name: "palaver-lm", dependencies: ["PalaverLM", "PalaverMLX"], swiftSettings: v5),
        .testTarget(name: "PalaverLMTests", dependencies: ["PalaverLM", "PalaverCloud", "PalaverDomain", "PalaverCore"],
                    swiftSettings: v5),
        .testTarget(name: "PalaverMLXTests", dependencies: ["PalaverMLX", "PalaverLM", "PalaverCloud", "PalaverDomain", "PalaverCore"],
                    swiftSettings: v5),
        .testTarget(name: "PalaverWorkerTests", dependencies: ["PalaverWorker", "PalaverDomain", "PalaverEngine", "PalaverCore", "PalaverCloud",
                                                         .product(name: "FluidAudio", package: "FluidAudio")],
                    swiftSettings: v5),
    ]
)
