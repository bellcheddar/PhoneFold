import Foundation
import simd
import FoldCore
import FoldGeometry
import FoldEngine
import FoldAudio
import FoldCapture

// PLAN.md Phase 5a: "Batch mode: drop a multi-record FASTA or a list of accessions, fold them
// all, produce a film per protein overnight."
//
// The headless half of that, and the thing 5a's machine gate runs. Studio's drag-and-drop
// surface calls the same `BatchRunner`.

struct Options {
    var input = ""
    var out = "batch-out"
    var library: String?
    var engine = "simulate"
    var styles = URL(fileURLWithPath: "Apps/Shared/Resources/Styles")
    var style = "fantasy"
    var steps: Int?
    var frames = 180
    var cif = false
    var midi = false
    var wav = false
    var film = false
    var quiet = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: fold-batch <records.fasta | accessions.txt> [options]

      --out <dir>         where the results go (default batch-out)
      --library <dir>     resolve identifiers from local .pftraj files instead of AlphaFold.
                          This is what makes a run reproducible and offline; without it every
                          record is a network fetch.
      --engine <name>     simulate | morph        (default simulate)
      --steps <n>         steps for the structure-based model
      --frames <n>        frames per protein (default 180). The dominant cost: every frame
                          re-derives contacts and secondary structure, so halving this roughly
                          halves the run. The gate uses a small number because it is testing
                          the orchestration, not the animation
      --style <id>        style profile for audio and film (default fantasy)
      --styles <dir>      where the style profiles live
      --cif               write a multi-model mmCIF per protein
      --midi              write a MIDI file per protein
      --wav               write the score per protein
      --film              write an MP4 per protein, with its music. The expensive one
      --quiet             only the final report

    With no output flag it folds and reports without writing anything, which is the cheapest
    way to find out which of fifty identifiers actually resolve.

    """.utf8))
    exit(2)
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty { usage() }

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
        index += 1
        guard index < arguments.count else { usage() }
        return arguments[index]
    }
    switch argument {
    case "--out": options.out = value()
    case "--library": options.library = value()
    case "--engine": options.engine = value()
    case "--steps": options.steps = Int(value())
    case "--frames": options.frames = Int(value()) ?? 180
    case "--style": options.style = value()
    case "--styles": options.styles = URL(fileURLWithPath: value())
    case "--cif": options.cif = true
    case "--midi": options.midi = true
    case "--wav": options.wav = true
    case "--film": options.film = true
    case "--quiet": options.quiet = true
    case "-h", "--help": usage()
    default:
        if argument.hasPrefix("-") { usage() }
        options.input = argument
    }
    index += 1
}
if options.input.isEmpty { usage() }

let quiet = options.quiet
func say(_ message: String) {
    if !quiet { print(message); fflush(stdout) }
}

/// Resolve an identifier from a directory of `.pftraj` files.
///
/// **The offline path, and the one the gate uses.** A batch that has to reach AlphaFold for
/// every record is not reproducible and cannot run in a phase gate: it fails on a train. The
/// library is keyed by each bundle's own `metadata.accession`, so nothing here is a hand-written
/// mapping that could drift from what the files actually contain.
func loadLibrary(_ directory: URL) throws -> [String: ReferenceStructure] {
    var byIdentifier: [String: ReferenceStructure] = [:]
    let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "pftraj" }
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let bundle = try TrajectoryBundleCodec.read(contentsOf: file)
        guard let last = bundle.readouts.last else { continue }
        let identifier = bundle.metadata.accession
            ?? file.deletingPathExtension().lastPathComponent
        let ca = last.caPositions.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        byIdentifier[identifier.uppercased()] = ReferenceStructure(
            accession: identifier,
            name: bundle.metadata.name,
            sequence: bundle.metadata.sequence,
            caPositions: ca,
            pLDDT: last.confidence)
    }
    return byIdentifier
}

do {
    let text = try String(contentsOf: URL(fileURLWithPath: options.input), encoding: .utf8)
    let input = BatchInput.parse(text)
    say("\(input.items.count) to fold, \(input.rejections.count) not read")

    let engine: FoldingEngine = options.engine == "morph" ? .morph : .structureBased
    let outputDirectory = URL(fileURLWithPath: options.out)
    let wantsOutput = options.cif || options.midi || options.wav || options.film
    if wantsOutput {
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
    }

    let profiles = try StyleLibrary.profiles(in: options.styles)
    guard let style = profiles[options.style] else {
        FileHandle.standardError.write(Data(
            "no style '\(options.style)' in \(options.styles.path)\n".utf8))
        exit(1)
    }

    let library = try options.library.map { try loadLibrary(URL(fileURLWithPath: $0)) }
    if let library { say("library: \(library.count) structures") }
    let alphaFold = AlphaFoldClient()

    let resolve: BatchRunner.Resolver = { identifier in
        if let library {
            guard let reference = library[identifier.uppercased()] else {
                throw BatchFailure.notInLibrary(identifier, known: library.keys.sorted())
            }
            return reference
        }
        return try await alphaFold.reference(for: identifier)
    }

    let runner = BatchRunner(engine: engine, steps: options.steps,
                             frameCount: options.frames)
    let started = Date()

    let summary = await runner.run(
        input,
        resolve: resolve,
        progress: { index, total, identifier in
            say("[\(index + 1)/\(total)] \(identifier)")
        },
        deliver: { bundle, item in
            guard wantsOutput else { return }
            let stem = item.label ?? item.accession
            let base = outputDirectory.appending(path: stem)

            // The frame stream, paced from the score so picture and sound end together. Built
            // once and shared by every output, because rebuilding it per format would fold the
            // same protein three times.
            let provider = try SampleTrajectoryProvider(bundle: bundle)
            let readouts = provider.readouts.count
            let pacing = Sonifier.pacing(readouts: readouts, style: style)
            let sequence = FoldFrameSequence(provider: provider, configuration: .init(
                frameRate: 60,
                secondsPerRawFrame: Float(pacing.secondsPerReadout(readouts: readouts,
                                                                  style: style))))
            var frames: [FoldFrame] = []
            for try await frame in sequence { frames.append(frame) }

            if options.cif {
                let raw = frames.filter { !$0.isInterpolated }
                let header = MMCIFExport.Header(
                    entryID: bundle.metadata.accession ?? stem,
                    title: bundle.metadata.name,
                    sequence: bundle.metadata.sequence,
                    confidenceSource: bundle.metadata.provenance.confidenceSource,
                    disclosure: bundle.metadata.provenance.disclosure)
                let traceOnly = bundle.readouts.first?.backbone == nil
                try MMCIFExport.write(frames: raw, residues: bundle.residues, header: header,
                                      backboneOnly: traceOnly)
                    .write(to: base.appendingPathExtension("cif"), atomically: true,
                           encoding: .utf8)
            }

            if options.midi || options.wav || options.film {
                var sonifier = Sonifier(style: style, residues: bundle.residues,
                                        beatsPerMoment: pacing.beatsPerMoment,
                                        readoutsPerMoment: pacing.readoutsPerMoment)
                var score: [ScoreMoment] = []
                for frame in frames {
                    if let moment = sonifier.moment(for: frame) { score.append(moment) }
                }
                if options.midi {
                    try MIDIFile.encode(score, style: style)
                        .write(to: base.appendingPathExtension("mid"))
                }
                if options.wav {
                    let rendered = OfflineRender().render(score, style: style,
                                                          residueCount: bundle.residues.count)
                    try OfflineRender.wav(left: rendered.left, right: rendered.right,
                                          sampleRate: 48_000)
                        .write(to: base.appendingPathExtension("wav"))
                }
            }

            if options.film {
                var exportOptions = FilmExporter.Options()
                exportOptions.caption = FilmOverlay.Caption(
                    name: bundle.metadata.name,
                    accession: bundle.metadata.accession,
                    residueCount: bundle.residues.count,
                    confidence: frames.last?.meanPLDDT,
                    confidenceSource: bundle.metadata.provenance.confidenceSource,
                    provenance: bundle.metadata.provenance.isGenerated ? "generated" : nil)
                _ = try await FilmExporter(options: exportOptions).export(
                    frames: frames, residues: bundle.residues, style: style,
                    to: base.appendingPathExtension("mp4"))
            }
        })

    let elapsed = Date().timeIntervalSince(started)
    print(summary.report)
    print(String(format: "%.1f s", elapsed))
    if wantsOutput { print("output in \(outputDirectory.path)") }

    // A batch that folded nothing is a failure even though every individual step "worked":
    // an overnight run that exits 0 having produced no films is the worst possible outcome.
    exit(summary.succeeded == 0 && !input.items.isEmpty ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

enum BatchFailure: Error, CustomStringConvertible {
    case notInLibrary(String, known: [String])

    var description: String {
        switch self {
        case .notInLibrary(let identifier, let known):
            "\(identifier) is not in the library (it holds \(known.prefix(6).joined(separator: ", "))"
                + (known.count > 6 ? ", and \(known.count - 6) more)" : ")")
        }
    }
}
