import Foundation
import FoldCore
import FoldGeometry
import FoldEngine
import FoldAudio

/// What a batch writes for each protein it folds.
///
/// **One definition, used by the command line and by Studio.** `BatchRunner` deliberately takes
/// a closure and knows nothing about films, because `FoldEngine` has no platform code in it.
/// That leaves the question of where the closure's body lives, and the answer cannot be "in both
/// callers": the moment the CLI and the app each have their own copy, one of them starts writing
/// a different mmCIF header or a differently paced film, and nothing notices.
public struct BatchDelivery: Sendable {

    /// Which files to write. Nothing is written by default, which is the cheapest way to find
    /// out which of fifty identifiers actually resolve.
    public struct Formats: Sendable, Equatable {
        public var mmCIF = false
        public var midi = false
        public var wav = false
        public var film = false
        /// PLAN.md Phase 5a's image sequence, for grading. Its own flag rather than a film
        /// option: someone taking frames into a compositor wants the frames and not a movie.
        public var imageSequence = false

        public var wantsAnything: Bool { mmCIF || midi || wav || film || imageSequence }
        /// The score is needed for three of these, so it is built once when any of them is on.
        /// An image sequence has no soundtrack and does not need it.
        public var needsScore: Bool { midi || wav || film }

        public init(mmCIF: Bool = false, midi: Bool = false, wav: Bool = false,
                    film: Bool = false, imageSequence: Bool = false) {
            self.mmCIF = mmCIF
            self.midi = midi
            self.wav = wav
            self.film = film
            self.imageSequence = imageSequence
        }
    }

    public var formats: Formats
    public var style: StyleProfile
    public var directory: URL
    /// How long the piece should last, which is what actually decides the cost of a batch.
    ///
    /// **Measured, after the obvious answer turned out to be wrong.** The obvious answer was the
    /// bundle's readout count, and this type carried a `frameCount` that was never read - a knob
    /// that looked like it worked. Cutting readouts from 180 to 48 changed a five-protein run
    /// from 1237 s to 1217 s, which is 1.6% for a 73% cut, because `Sonifier.pacing` normalises
    /// to a target *duration*: fewer readouts simply hold each one on screen for longer and the
    /// stream is about 2,700 frames either way. Folding all five takes 0.1 s; the whole rest of
    /// the run is those frames, each re-deriving contacts and secondary structure.
    ///
    /// So this is the lever, and it is honest about what it costs: a shorter target is a shorter
    /// film, not the same film computed faster.
    public var targetSeconds: Double
    public var filmSize: OffscreenStage.Size
    public var codec: FilmWriter.Codec

    public init(formats: Formats, style: StyleProfile, directory: URL,
                targetSeconds: Double = Sonifier.targetSeconds,
                filmSize: OffscreenStage.Size = .landscape,
                codec: FilmWriter.Codec = .h264) {
        self.formats = formats
        self.style = style
        self.directory = directory
        self.targetSeconds = targetSeconds
        self.filmSize = filmSize
        self.codec = codec
    }

    /// Files written for one protein, so a caller can say what it produced rather than guessing.
    public struct Written: Sendable, Equatable {
        public var urls: [URL] = []
        public var frames = 0
    }

    /// Write everything asked for, for one folded protein.
    @discardableResult
    public func write(_ bundle: TrajectoryBundle, stem: String) async throws -> Written {
        guard formats.wantsAnything else { return Written() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A stem from a FASTA label is not a filename until it has been made into one.
        let safe = Self.filename(stem)
        let base = directory.appending(path: safe)
        var written = Written()

        // The frame stream, paced from the score so picture and sound end together. Built once
        // and shared by every format, because rebuilding it per format would fold the same
        // protein three times.
        let provider = try SampleTrajectoryProvider(bundle: bundle)
        let readouts = provider.readouts.count
        let pacing = Sonifier.pacing(readouts: readouts, style: style,
                                     targetSeconds: targetSeconds)
        let sequence = FoldFrameSequence(provider: provider, configuration: .init(
            frameRate: 60,
            secondsPerRawFrame: Float(pacing.secondsPerReadout(readouts: readouts, style: style))))
        var frames: [FoldFrame] = []
        for try await frame in sequence { frames.append(frame) }
        written.frames = frames.count

        if formats.mmCIF {
            let raw = frames.filter { !$0.isInterpolated }
            let header = MMCIFExport.Header(
                entryID: bundle.metadata.accession ?? safe,
                title: bundle.metadata.name,
                sequence: bundle.metadata.sequence,
                confidenceSource: bundle.metadata.provenance.confidenceSource,
                disclosure: bundle.metadata.provenance.disclosure)
            // Alpha carbons only unless the provider carried a real backbone: a CA-trace fold
            // has no N, C or O, and writing four atoms from one would be inventing three.
            let traceOnly = bundle.readouts.first?.backbone == nil
            let url = base.appendingPathExtension("cif")
            try MMCIFExport.write(frames: raw, residues: bundle.residues, header: header,
                                  backboneOnly: traceOnly)
                .write(to: url, atomically: true, encoding: .utf8)
            written.urls.append(url)
        }

        if formats.needsScore {
            var sonifier = Sonifier(style: style, residues: bundle.residues,
                                    beatsPerMoment: pacing.beatsPerMoment,
                                    readoutsPerMoment: pacing.readoutsPerMoment)
            var score: [ScoreMoment] = []
            for frame in frames {
                if let moment = sonifier.moment(for: frame) { score.append(moment) }
            }

            if formats.midi {
                let url = base.appendingPathExtension("mid")
                try MIDIFile.encode(score, style: style).write(to: url)
                written.urls.append(url)
            }
            if formats.wav {
                let rendered = OfflineRender().render(score, style: style,
                                                      residueCount: bundle.residues.count)
                let url = base.appendingPathExtension("wav")
                try OfflineRender.wav(left: rendered.left, right: rendered.right,
                                      sampleRate: 48_000).write(to: url)
                written.urls.append(url)
            }
            if formats.film {
                var options = FilmExporter.Options()
                options.size = filmSize
                options.codec = codec
                // The same target the frames above were paced to. The exporter builds its own
                // score and refuses a mismatch, which is what caught this.
                options.targetSeconds = targetSeconds
                options.caption = FilmOverlay.Caption(
                    name: bundle.metadata.name,
                    accession: bundle.metadata.accession,
                    residueCount: bundle.residues.count,
                    confidence: frames.last?.meanPLDDT,
                    confidenceSource: bundle.metadata.provenance.confidenceSource,
                    provenance: bundle.metadata.provenance.isGenerated ? "generated" : nil)
                // The extension follows the container, which follows the codec. A ProRes
                // film named .mp4 lies to every tool that sniffs by extension.
                let url = base.appendingPathExtension(codec.fileExtension)
                _ = try await FilmExporter(options: options).export(
                    frames: frames, residues: bundle.residues, style: style, to: url)
                written.urls.append(url)
            }
        }

        if formats.imageSequence {
            var options = ImageSequenceExporter.Options()
            options.size = filmSize
            let directory = base.appendingPathExtension("frames")
            _ = try await ImageSequenceExporter(options: options).export(
                frames: frames, residues: bundle.residues, to: directory)
            written.urls.append(directory)
        }
        return written
    }

    /// Make a filename out of an entry name.
    ///
    /// FASTA labels are not filenames. `sp|P69905|HBA_HUMAN` is fine, but real files carry
    /// slashes and colons in their descriptions, and one of those turns a write into a write
    /// somewhere else entirely, or into a failure at record 40 of an overnight run.
    public static func filename(_ stem: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return trimmed.isEmpty ? "protein" : String(trimmed.prefix(80))
    }
}
