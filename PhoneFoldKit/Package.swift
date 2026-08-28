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
    ],
    targets: [
        .target(name: "FoldCore"),
        .target(name: "FoldGeometry", dependencies: ["FoldCore"],
                resources: [.copy("Resources/sse_classifier.json")]),
        .target(name: "FoldEngine", dependencies: ["FoldCore", "FoldGeometry"]),
        .target(name: "FoldAudio", dependencies: ["FoldCore"]),
        .target(name: "FoldRender", dependencies: ["FoldCore"]),
        .target(name: "FoldCapture", dependencies: ["FoldCore", "FoldRender"]),
        .target(name: "FoldSync", dependencies: ["FoldCore"]),

        .testTarget(name: "FoldCoreTests", dependencies: ["FoldCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FoldGeometryTests", dependencies: ["FoldGeometry"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FoldEngineTests", dependencies: ["FoldEngine"]),
        .testTarget(name: "FoldAudioTests", dependencies: ["FoldAudio"]),
        .testTarget(name: "FoldRenderTests", dependencies: ["FoldRender", "FoldGeometry"]),
        .testTarget(name: "FoldCaptureTests", dependencies: ["FoldCapture"]),
        .testTarget(name: "FoldSyncTests", dependencies: ["FoldSync"]),
    ],
    swiftLanguageModes: [.v6]
)
