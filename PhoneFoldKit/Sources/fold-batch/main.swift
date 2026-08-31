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
    var seconds: Double?
    var cif = false
    var midi = false
    var wav = false
    var film = false
    var frames_png = false
    var codec = "h264"
    var size = "1080"
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
      --readouts <n>      readouts captured per fold (default 180). This is NOT the cost of a
                          run: the piece is paced to a target duration, so fewer readouts are
                          simply held on screen for longer. Measured: 180 to 48 moved a
                          five-protein run by 1.6%
      --seconds <n>       target duration per protein (default 45). This IS the cost: the frame
                          stream is 60 a second and each frame re-derives contacts and secondary
                          structure. A shorter target is a shorter film, not the same film
                          computed faster
      --style <id>        style profile for audio and film (default fantasy)
      --styles <dir>      where the style profiles live
      --cif               write a multi-model mmCIF per protein
      --midi              write a MIDI file per protein
      --wav               write the score per protein
      --film              write a film per protein, with its music. The expensive one
      --image-sequence    write a numbered PNG sequence per protein, for grading. Not
                          --frames: that name meant the readout count until 2026-08-31 and
                          reusing it would silently change what an old command line does
      --codec <name>      h264 | hevc | prores422hq | prores4444   (default h264)
                          ProRes writes a .mov with uncompressed audio, not a .mp4
      --size <name>       1080 | vertical | 4k                     (default 1080)
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
    case "--readouts": options.frames = Int(value()) ?? 180
    case "--seconds": options.seconds = Double(value())
    case "--style": options.style = value()
    case "--styles": options.styles = URL(fileURLWithPath: value())
    case "--cif": options.cif = true
    case "--midi": options.midi = true
    case "--wav": options.wav = true
    case "--film": options.film = true
    case "--image-sequence": options.frames_png = true
    case "--codec": options.codec = value().lowercased()
    case "--size": options.size = value().lowercased()
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
        || options.frames_png

    let codec: FilmWriter.Codec = switch options.codec {
    case "hevc": .hevc
    case "prores422hq", "prores": .proRes422HQ
    case "prores4444": .proRes4444
    default: .h264
    }
    let filmSize: OffscreenStage.Size = switch options.size {
    case "vertical": .vertical
    case "4k", "uhd": .ultraHD
    default: .landscape
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

    let delivery = BatchDelivery(
        formats: .init(mmCIF: options.cif, midi: options.midi,
                       wav: options.wav, film: options.film,
                       imageSequence: options.frames_png),
        style: style, directory: outputDirectory,
        targetSeconds: options.seconds ?? Sonifier.targetSeconds,
        filmSize: filmSize, codec: codec)

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
            // One definition of what a batch writes, shared with Studio. See BatchDelivery.
            try await delivery.write(bundle, stem: item.label ?? item.accession)
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
