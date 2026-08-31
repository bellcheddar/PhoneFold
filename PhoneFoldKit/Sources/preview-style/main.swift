import Foundation
import simd
import FoldCore
import FoldGeometry
import FoldEngine
import FoldAudio
import FoldRender
import FoldCapture
import RealityKit

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
    var midi: String?
    var cif: String?
    var still: String?
    var film: String?
    var filmSize = "1080"
    var caption = true
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
      --midi <file.mid>   also write a standard MIDI file of the same score
      --cif <file.cif>    also write the trajectory as a multi-model mmCIF
      --still <file.png>  also render the final frame offscreen at 1920x1080
      --film <file.mp4>   render the whole fold as a film, with its music
      --size <preset>     1080 | vertical | 4k   (default 1080)
      --no-caption        leave the film clean, with no burned-in caption
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
    case "--midi": options.midi = value()
    case "--cif": options.cif = value()
    case "--still": options.still = value()
    case "--film": options.film = value()
    case "--size": options.filmSize = value()
    case "--no-caption": options.caption = false
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
    // Paced from the score, exactly as the app paces its animation, so the picture and the
    // sound finish together. The sequence's own default is an eighth of a second per readout,
    // which for a live fold is a fifteen-second picture against a thirty-eight-second piece.
    let readoutCount = provider.readouts.count
    let framePacing = Sonifier.pacing(readouts: readoutCount, style: style)
    let sequence = FoldFrameSequence(provider: provider, configuration: .init(
        frameRate: 60,
        secondsPerRawFrame: Float(framePacing.secondsPerReadout(readouts: readoutCount,
                                                               style: style))))
    var frames: [FoldFrame] = []
    for try await frame in sequence { frames.append(frame) }

    let readouts = frames.count { !$0.isInterpolated }
    let pacing = Sonifier.pacing(readouts: readouts, style: style)
    say("pacing: \(readouts) readouts -> \(pacing.moments) moments of "
        + String(format: "%.2f", pacing.beatsPerMoment) + " beats "
        + "(\(pacing.readoutsPerMoment) readout\(pacing.readoutsPerMoment == 1 ? "" : "s") each)")
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

    if let path = options.film {
        var exportOptions = FilmExporter.Options()
        switch options.filmSize {
        case "vertical": exportOptions.size = .vertical
        case "4k": exportOptions.size = .ultraHD
        default: exportOptions.size = .landscape
        }
        if options.caption {
            var caption = FilmOverlay.Caption(
                name: bundle.metadata.name,
                accession: bundle.metadata.accession,
                residueCount: bundle.residues.count,
                confidence: frames.last?.meanPLDDT,
                confidenceSource: bundle.metadata.provenance.confidenceSource,
                provenance: bundle.metadata.provenance.isGenerated ? "generated" : nil)
            caption.mark = "PhoneFold"
            exportOptions.caption = caption
        }
        say("rendering \(frames.count) frames at \(exportOptions.size.width)x\(exportOptions.size.height)...")
        let exporter = FilmExporter(options: exportOptions)
        var lastReport = 0
        let summary = try await exporter.export(
            frames: frames, residues: bundle.residues, style: style,
            to: URL(fileURLWithPath: path)) { fraction in
                let percent = Int(fraction * 100)
                if percent >= lastReport + 20 { lastReport = percent; say("  \(percent)%") }
            }
        say(String(format: "film -> %@  %d frames, %.1f s picture, %.1f s sound (drift %.2f s), %d bars",
                   path, summary.frames, summary.videoSeconds, summary.audioSeconds,
                   summary.drift, summary.bars))
    }

    if let path = options.still, let final = frames.last {
        // The offscreen pass, at export resolution, driven by the same frames the film will
        // be. Nothing is on screen: this runs on a machine with no window.
        let stage = try OffscreenStage(size: .landscape)
        let ca = final.backbone.map(\.ca)
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: final.secondaryStructure)
        let options2 = ColourOptions(residueCount: bundle.residues.count,
                                     residues: bundle.residues)
        try stage.show(mesh: mesh, confidence: final.pLDDT, mode: .secondaryStructure,
                       options: options2)
        // Framing is the stage's own, and it is the live view's: the protein is normalised to
        // a fixed extent and the camera sits where StageCamera puts it, so a 20-residue
        // miniprotein and a 300-residue one both fill the frame identically to the app.
        _ = try await stage.render()
        // The caption goes on the still too, which is how it gets looked at without waiting
        // for a film.
        var pixels = stage.readPixels()
        if options.caption,
           let overlay = FilmOverlay(caption: FilmOverlay.Caption(
                name: bundle.metadata.name, accession: bundle.metadata.accession,
                residueCount: bundle.residues.count, confidence: final.meanPLDDT,
                confidenceSource: bundle.metadata.provenance.confidenceSource,
                provenance: bundle.metadata.provenance.isGenerated ? "generated" : nil),
                size: .landscape) {
            // The still is RGBA and the overlay is BGRA, so it is blended into a swapped copy
            // and swapped back - the film writer blends straight into a BGRA pixel buffer.
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels.swapAt(i, i + 2)
            }
            pixels.withUnsafeMutableBufferPointer { raw in
                overlay.blend(into: raw.baseAddress!, bytesPerRow: 1920 * 4)
            }
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels.swapAt(i, i + 2)
            }
        }
        if let png = OffscreenStage.png(pixels: pixels, size: .landscape) {
            try png.write(to: URL(fileURLWithPath: path))
            say("still -> \(path) (1920x1080)")
        }
    }

    if let path = options.cif {
        let raw = frames.filter { !$0.isInterpolated }
        let header = MMCIFExport.Header(
            entryID: bundle.metadata.accession ?? (options.trajectory as NSString)
                .lastPathComponent.replacingOccurrences(of: ".pftraj", with: ""),
            title: bundle.metadata.name,
            sequence: bundle.metadata.sequence,
            confidenceSource: bundle.metadata.provenance.confidenceSource,
            disclosure: bundle.metadata.provenance.disclosure)
        // Alpha carbons only unless the provider carried a real backbone: a CA-trace fold has
        // no N, C or O, and writing four atoms from one would be inventing three. Asked of the
        // readouts rather than assumed, so a provider that does carry a backbone exports one.
        let traceOnly = bundle.readouts.first?.backbone == nil
        try MMCIFExport.write(frames: raw, residues: bundle.residues, header: header,
                              backboneOnly: traceOnly)
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        say("cif -> \(path) (\(raw.count) models, \(traceOnly ? "CA trace" : "full backbone"))")
    }

    if let path = options.midi {
        try MIDIFile.encode(score, style: style).write(to: URL(fileURLWithPath: path))
        say("midi -> \(path)")
    }

    print(String(format:
        "%@ %@ %@  %.1fs  peak %.3f  rms %.4f  %.1f LUFS  starved %d  refused %d  -> %@",
        (options.trajectory as NSString).lastPathComponent, options.engine, style.id,
        result.duration, Double(result.peak), Double(result.rms), result.loudness,
        result.starvedBeats, result.refusedNotes, options.output))
} catch {
    FileHandle.standardError.write(Data("preview-style failed: \(error)\n".utf8))
    exit(1)
}
