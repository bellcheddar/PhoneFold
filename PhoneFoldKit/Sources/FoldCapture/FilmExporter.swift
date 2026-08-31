import Foundation
import simd
import FoldCore
import FoldGeometry
import FoldRender
import FoldAudio

/// A fold, its music, and one MP4 with both in it.
///
/// PLAN.md Phase 4's `.mp4` export: "The film, with music." It drives the same three things the
/// app does - `TubeGeometry` for the mesh, `OffscreenStage` for the picture, `FoldAudioEngine`
/// for the sound - so what is exported is what was on screen and in the ears, at a different
/// resolution.
///
/// **The soundtrack is rendered through the real audio graph**, not through the offline stereo
/// path. `FoldAudioEngine`'s manual rendering mode gives the same `AVAudioEnvironmentNode` and
/// the same HRTF the live app uses, so the film carries the spatial mix rather than a flat
/// approximation of it.
@MainActor
public struct FilmExporter {

    public struct Options: Sendable {
        public var size: OffscreenStage.Size = .landscape
        public var codec: FilmWriter.Codec = .h264
        public var frameRate: Int32 = 60
        public var colourMode: ColourMode = .secondaryStructure
        /// Seconds of tail so the last notes ring out rather than being cut off.
        public var tail: Double = 2.5

        public init() {}
    }

    public struct Summary: Sendable {
        public let url: URL
        public let frames: Int
        public let videoSeconds: Double
        public let audioSeconds: Double
        public let bars: Int
        /// Frames of the final structure held while the music finished.
        public let heldFrames: Int
        /// How far the picture and the sound disagree about the length of the piece.
        public var drift: Double { abs(videoSeconds - audioSeconds) }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Write the film.
    public func export(frames: [FoldFrame], residues: [AminoAcid], style: StyleProfile,
                       to url: URL,
                       progress: (@MainActor (Double) -> Void)? = nil) async throws -> Summary {
        guard !frames.isEmpty else {
            throw FilmWriter.Failure.couldNotCreate("the trajectory has no frames")
        }

        // Score first, keeping each bar with the coordinates that produced it: the spatial mix
        // places every note at its residue's position *at the moment it was written*, and by
        // the time the note sounds the fold has moved on.
        let readouts = frames.count { !$0.isInterpolated }
        let pacing = Sonifier.pacing(readouts: readouts, style: style)
        var sonifier = Sonifier(style: style, residues: residues,
                                beatsPerMoment: pacing.beatsPerMoment,
                                readoutsPerMoment: pacing.readoutsPerMoment)
        var bars: [(moment: ScoreMoment, positions: [SIMD3<Float>])] = []
        for frame in frames {
            guard let moment = sonifier.moment(for: frame) else { continue }
            bars.append((moment, frame.backbone.map(\.ca)))
        }

        var musicSeconds = options.tail
        for bar in bars {
            musicSeconds += MusicalClock.momentDuration(tempo: bar.moment.tempo,
                                                        beats: bar.moment.beats)
        }

        // The soundtrack, through the real graph.
        let engine = FoldAudioEngine(style: style, residueCount: residues.count)
        var next = 0
        let audio = try engine.renderOffline(seconds: musicSeconds) { now, engine in
            while next < bars.count, engine.nextBeat < now + 4 {
                engine.submit(bars[next].moment, positions: bars[next].positions)
                next += 1
            }
        }

        // **The two clocks are checked before a frame is drawn.** The caller supplies the
        // frames and the score supplies the bars, and both are meant to come from the same
        // pacing - so a picture four seconds long against a forty-seven-second soundtrack is
        // not a film with a long tail, it is a caller that paced its frames by some other rule.
        // Rendering it anyway would produce a file that looks finished and is not.
        let videoSeconds = Double(frames.count) / Double(options.frameRate)
        let summary = Summary(url: url, frames: frames.count, videoSeconds: videoSeconds,
                              audioSeconds: musicSeconds, bars: bars.count, heldFrames: 0)
        let longer = Swift.max(videoSeconds, musicSeconds)
        guard longer > 0, summary.drift <= longer * 0.5 else {
            throw FilmWriter.Failure.couldNotCreate(String(
                format: "the picture is %.1f s and the sound is %.1f s; the frames were not "
                    + "paced from the same rule as the score", videoSeconds, musicSeconds))
        }

        // The picture. **The soundtrack goes in first**: `AVAssetWriter` interleaves its
        // tracks and stops accepting video once it is far ahead of an audio track that still
        // expects data, so writing every frame and then the sound deadlocks on anything longer
        // than a few seconds.
        let stage = try OffscreenStage(size: options.size)
        let writer = try FilmWriter(url: url, size: options.size,
                                    frameRate: options.frameRate, codec: options.codec)
        try writer.appendAudio(left: audio.left, right: audio.right)
        let step = 1 / Float(options.frameRate)
        let colourOptions = ColourOptions(residueCount: residues.count, residues: residues)
        for (index, frame) in frames.enumerated() {
            let mesh = TubeGeometry.build(caPositions: frame.backbone.map(\.ca),
                                          secondaryStructure: frame.secondaryStructure)
            try stage.show(mesh: mesh, confidence: frame.pLDDT, mode: options.colourMode,
                           options: colourOptions)
            stage.advance(by: step)
            _ = try await stage.render()
            try writer.append(texture: stage.texture)
            progress?(Double(index + 1) / Double(frames.count))
        }

        // **Hold the last frame while the music rings out.**
        //
        // The frame count is chosen from the style's midpoint tempo, but the accelerando means
        // the piece's real length is not that estimate - and there is a tail besides. Measured:
        // a villin fold gave 44.8 s of picture against 51.7 s of sound, so the last seven
        // seconds played over the end of the file. Repeating the final frame is what the
        // moment wants anyway: the cadence resolving over the finished protein.
        var held = 0
        while Double(frames.count + held) / Double(options.frameRate) < musicSeconds {
            try writer.append(texture: stage.texture)
            held += 1
        }

        try await writer.finish()
        return Summary(url: url, frames: frames.count + held,
                       videoSeconds: Double(frames.count + held) / Double(options.frameRate),
                       audioSeconds: musicSeconds, bars: bars.count, heldFrames: held)
    }
}
