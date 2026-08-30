import Foundation
import simd
import FoldCore
import FoldGeometry
import FoldEngine
import FoldAudio

// PLAN.md Phase 3: "Build Tools/preview_style.swift, a command-line renderer that turns a
// sample trajectory plus a style profile into a WAV. This lets the loop regression-test audio
// without a device, and lets Marc audition style tweaks in seconds."
//
// It runs the same sonifier and the same ScorePlayer the app does, so what comes out is the
// piece rather than an approximation of it.

struct Options {
    var trajectory: String = ""
    var styles: URL = URL(fileURLWithPath: "Apps/Shared/Resources/Styles")
    var style = "fantasy"
    var engine = "gallery"
    var steps: Int?
    var output = "preview.wav"
    var quiet = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: preview-style <trajectory.pftraj> [options]

      --style <id>        style profile to render with (default fantasy)
      --styles <dir>      where the style profiles live
      --engine <name>     gallery | morph | simulate  (default gallery)
                          morph and simulate fold toward the trajectory's final structure
      --steps <n>         steps for the structure-based model
      --out <file.wav>    where to write (default preview.wav)
      --quiet             print only the summary line

    """.utf8))
    exit(2)
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    func value() -> String {
        guard let next = arguments.first else { usage() }
        arguments.removeFirst()
        return next
    }
    switch argument {
    case "--style": options.style = value()
    case "--styles": options.styles = URL(fileURLWithPath: value())
    case "--engine": options.engine = value()
    case "--steps": options.steps = Int(value())
    case "--out": options.output = value()
    case "--quiet": options.quiet = true
    case "-h", "--help": usage()
    default:
        guard options.trajectory.isEmpty else { usage() }
        options.trajectory = argument
    }
}
guard !options.trajectory.isEmpty else { usage() }

// Captured rather than read from the global: top-level code is main-actor isolated, and a
// nonisolated function may not reach into it.
let quiet = options.quiet
func say(_ message: String) {
    if !quiet { print(message) }
}

do {
    let profiles = try StyleLibrary.profiles(in: options.styles)
    guard let style = profiles[options.style] else {
        FileHandle.standardError.write(Data(
            "no style '\(options.style)' in \(options.styles.path); found \(profiles.keys.sorted())\n".utf8))
        exit(1)
    }

    let reference = try TrajectoryBundleCodec.read(
        contentsOf: URL(fileURLWithPath: options.trajectory))

    let bundle: TrajectoryBundle
    switch options.engine {
    case "gallery":
        bundle = reference
    case "morph", "simulate":
        guard let last = reference.readouts.last else {
            FileHandle.standardError.write(Data("the trajectory has no readouts\n".utf8))
            exit(1)
        }
        let native = last.caPositions.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let engine: FoldingEngine = options.engine == "morph" ? .morph : .structureBased
        say("folding \(reference.residues.count) residues with \(engine.displayName)...")
        bundle = try LiveTrajectory.fold(engine: engine, native: native,
                                         metadata: reference.metadata,
                                         residues: reference.residues,
                                         seed: 1, steps: options.steps, frameCount: 180)
    default:
        usage()
    }

    let provider = try SampleTrajectoryProvider(bundle: bundle)
    var frames: [FoldFrame] = []
    for try await frame in FoldFrameSequence(provider: provider) { frames.append(frame) }

    let score = Sonifier.score(style: style, residues: bundle.residues, frames: frames)
    let dropped = score.reduce(0) { $0 + $1.droppedContacts }
    let established = score.reduce(0) { $0 + $1.establishedContacts }
    let notes = score.reduce(0) { $0 + $1.notes.count }
    let cadence = score.firstIndex(where: \.isCadence)

    say("\(score.count) bars, \(notes) notes, \(established) established contacts, \(dropped) dropped")
    say("cadence: \(cadence.map { "bar \($0 + 1)" } ?? "never resolves")")

    let renderer = OfflineRender()
    let result = renderer.render(score, style: style, residueCount: bundle.residues.count)
    let data = OfflineRender.wav(left: result.left, right: result.right,
                                 sampleRate: result.sampleRate)
    try data.write(to: URL(fileURLWithPath: options.output))

    print(String(format:
        "%@ %@ %@  %.1fs  peak %.3f  rms %.4f  %.1f LUFS  starved %d  refused %d  -> %@",
        (options.trajectory as NSString).lastPathComponent, options.engine, style.id,
        result.duration, Double(result.peak), Double(result.rms), result.loudness,
        result.starvedBeats, result.refusedNotes, options.output))
} catch {
    FileHandle.standardError.write(Data("preview-style failed: \(error)\n".utf8))
    exit(1)
}
