// swift-tools-version: 6.2
import PackageDescription

// PhoneFoldKit is written once and is platform-agnostic.
//
// Dependency direction is strictly one way: FoldCore is depended upon by everything and
// depends on nothing. FoldRender and FoldAudio both consume FoldFrame and never talk to
// each other; the app layer wires them together.
//
// FoldCore, FoldEngine and FoldGeometry must contain no platform conditionals at all.
// Tools/verify_phase.sh enforces this on every gate run.

let package = Package(
    name: "PhoneFoldKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "FoldCore", targets: ["FoldCore"]),
        .library(name: "FoldGeometry", targets: ["FoldGeometry"]),
        .library(name: "FoldEngine", targets: ["FoldEngine"]),
        .library(name: "FoldAudio", targets: ["FoldAudio"]),
        .library(name: "FoldRender", targets: ["FoldRender"]),
        .library(name: "FoldCapture", targets: ["FoldCapture"]),
        .library(name: "FoldSync", targets: ["FoldSync"]),
        .executable(name: "foldaudio-probe", targets: ["foldaudio-probe"]),
        .executable(name: "preview-style", targets: ["preview-style"]),
    ],
    targets: [
        .target(name: "FoldCore"),
        .target(name: "FoldGeometry", dependencies: ["FoldCore"],
                resources: [.copy("Resources/sse_classifier.json")]),
        .target(name: "FoldEngine", dependencies: ["FoldCore", "FoldGeometry"]),
        .target(name: "FoldAudio", dependencies: ["FoldCore"]),
        .target(name: "FoldRender", dependencies: ["FoldCore"]),
        .target(name: "FoldCapture",
                dependencies: ["FoldCore", "FoldGeometry", "FoldRender", "FoldAudio"]),
        .target(name: "FoldSync", dependencies: ["FoldCore"]),

        // The allocation harness for PLAN.md's Phase 3 gate. An executable rather than a
        // test, because Darwin's only allocation counter is process-wide and swift-testing
        // runs suites in parallel: measured inside the test process the same loop reported 2
        // blocks alone and 8,092 under a full run. FoldAudioTests runs this and reads its
        // numbers.
        .executableTarget(name: "foldaudio-probe", dependencies: ["FoldAudio"]),

        // PLAN.md Phase 3's command-line renderer: a trajectory plus a style profile in, a WAV
        // out. Regression-tests audio without a device, and auditions a style tweak in
        // seconds.
        .executableTarget(name: "preview-style",
                          dependencies: ["FoldAudio", "FoldEngine", "FoldGeometry", "FoldCore",
                                         "FoldRender", "FoldCapture"]),

        .testTarget(name: "FoldCoreTests", dependencies: ["FoldCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FoldGeometryTests", dependencies: ["FoldGeometry"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FoldEngineTests", dependencies: ["FoldEngine", "FoldGeometry"],
                    resources: [.copy("Fixtures")]),
        // FoldAudio itself depends only on FoldCore. Its tests additionally pull in
        // FoldEngine so the sonifier can be run against a real bundled trajectory rather
        // than against frames a test made up - the mapping has to hold on the shapes the
        // engines actually produce, which is the failure a synthetic frame cannot catch.
        .testTarget(name: "FoldAudioTests", dependencies: ["FoldAudio", "FoldEngine"]),
        .testTarget(name: "FoldRenderTests", dependencies: ["FoldRender", "FoldGeometry"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FoldCaptureTests",
                    dependencies: ["FoldCapture", "FoldGeometry", "FoldRender", "FoldAudio"]),
        .testTarget(name: "FoldSyncTests", dependencies: ["FoldSync"]),
    ],
    swiftLanguageModes: [.v6]
)
