import Foundation
import Darwin
import simd
import FoldCore
import FoldGeometry
import FoldEngine
import FoldAudio
import FoldRender
import FoldCapture

// PLAN.md Phase 4's machine gate: "No memory leaks across 20 consecutive folds in an automated
// instrument run."
//
// Twenty folds **in one process**, because twenty separate runs of `preview-style` would prove
// nothing: each would start with a fresh heap and a leak would be reclaimed by exit every time.
// Each iteration does what a fold in the app does - simulate the trajectory, build the frame
// stream, score it, render the audio, and put frames through the offscreen Metal stage - and
// reports the process's physical footprint afterwards.
//
// Footprint rather than resident size: `phys_footprint` is the number Apple's own jetsam uses,
// and it counts the IOSurface and Metal allocations that a fold on this stage actually makes,
// which `resident_size` under-reports.

/// The process's physical footprint in bytes.
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                       / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let trajectory = repository.appending(path: "Apps/Shared/Resources/Trajectories/trp_cage.pftraj")
let stylesDirectory = repository.appending(path: "Apps/Shared/Resources/Styles")

guard FileManager.default.fileExists(atPath: trajectory.path) else {
    print("run from the repository root: \(trajectory.path) is not there")
    exit(1)
}

let folds = Int(ProcessInfo.processInfo.environment["PHONEFOLD_LEAK_FOLDS"] ?? "") ?? 20

let profiles = try StyleLibrary.profiles(in: stylesDirectory)
guard let style = profiles["fantasy"] else {
    print("no fantasy style in \(stylesDirectory.path)")
    exit(1)
}
let reference = try TrajectoryBundleCodec.read(contentsOf: trajectory)
guard let last = reference.readouts.last else {
    print("the trajectory has no readouts")
    exit(1)
}
let native = last.caPositions.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }

/// One fold, end to end.
///
/// `@MainActor` because `OffscreenStage` is: RealityKit's offscreen renderer is main-actor
/// isolated, and the app drives it from the main actor too.
@MainActor
func oneFold(seed: UInt64) async throws {
    let bundle = try LiveTrajectory.fold(
        engine: .structureBased, native: native, metadata: reference.metadata,
        residues: reference.residues, seed: seed, steps: 20_000, frameCount: 60)

    let provider = try SampleTrajectoryProvider(bundle: bundle)
    let readouts = provider.readouts.count
    let pacing = Sonifier.pacing(readouts: readouts, style: style)
    let sequence = FoldFrameSequence(provider: provider, configuration: .init(
        frameRate: 60,
        secondsPerRawFrame: Float(pacing.secondsPerReadout(readouts: readouts, style: style))))
    var frames: [FoldFrame] = []
    for try await frame in sequence { frames.append(frame) }

    var sonifier = Sonifier(style: style, residues: reference.residues,
                            beatsPerMoment: pacing.beatsPerMoment,
                            readoutsPerMoment: pacing.readoutsPerMoment)
    var score: [ScoreMoment] = []
    for frame in frames {
        if let moment = sonifier.moment(for: frame) { score.append(moment) }
    }
    _ = OfflineRender().render(score, style: style,
                               residueCount: reference.residues.count)

    // The offscreen stage, which is where the Metal and IOSurface allocations are. A handful of
    // frames rather than all of them: the leak, if there is one, is per-frame and shows up in
    // five as well as in three thousand, and a full film per iteration would make twenty folds
    // an hour rather than a few minutes.
    let stage = try OffscreenStage(size: OffscreenStage.Size(width: 640, height: 360))
    let colourOptions = ColourOptions(residueCount: reference.residues.count,
                                      residues: reference.residues)
    for frame in frames.prefix(5) {
        let mesh = TubeGeometry.build(caPositions: frame.backbone.map(\.ca),
                                      secondaryStructure: frame.secondaryStructure)
        try stage.show(mesh: mesh, confidence: frame.pLDDT, mode: .secondaryStructure,
                       options: colourOptions)
        stage.advance(by: 1.0 / 60)
        _ = try await stage.render()
    }
}

print("fold  footprint MB   delta MB")
var baseline: UInt64 = 0
var readings: [Double] = []
for index in 1...folds {
    try await oneFold(seed: UInt64(index))
    let now = footprint()
    if index == 1 { baseline = now }
    readings.append(mb(now))
    print(String(format: "%4d  %11.1f  %+9.1f", index, mb(now), mb(now) - mb(baseline)))
}

// The verdict is about the *trend over the settled half*, not the total. A first fold pays for
// every lazily-built cache in the process - Metal's device, the style profiles, the model - and
// counting that as a leak would fail a run that is behaving perfectly.
let settled = Array(readings.suffix(folds / 2))
let firstHalf = Array(readings.prefix(folds / 2))
let growth = (settled.reduce(0, +) / Double(settled.count))
    - (firstHalf.reduce(0, +) / Double(firstHalf.count))
let perFold = (readings.last ?? 0) - (readings.first ?? 0)
print(String(format: "\nfirst %.1f MB, last %.1f MB, mean second half minus first %+.1f MB",
             readings.first ?? 0, readings.last ?? 0, growth))
print(String(format: "growth per fold after the first: %+.2f MB",
             perFold / Double(max(folds - 1, 1))))
