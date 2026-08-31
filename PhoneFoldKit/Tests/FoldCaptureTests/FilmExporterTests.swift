import Testing
import Foundation
import AVFoundation
import simd
@testable import FoldCapture
import FoldCore
import FoldGeometry
import FoldRender
import FoldAudio

/// The whole export: a trajectory in, a film with music out.
///
/// PLAN.md's Phase 4 gate: "Offscreen export produces a valid MP4 with audio from a sample
/// trajectory in CI." A short synthetic trajectory rather than a real one, because this is
/// about the pipeline rather than about the fold - the fold is tested where it is computed.
@Suite("Film exporter", .serialized)
struct FilmExporterTests {

    /// How many rendered frames one readout gets, at a given frame rate.
    ///
    /// **The app's own rule, not a number.** The renderer and the score are both paced from
    /// `Sonifier.pacing`, and a test that invented a frame count would be testing its own
    /// arithmetic: the first version used four frames per readout and produced a four-second
    /// picture against a forty-seven-second soundtrack.
    static func framesPerReadout(rawFrames: Int, frameRate: Int32,
                                 style: StyleProfile) -> Int {
        let pacing = Sonifier.pacing(readouts: rawFrames, style: style)
        let tempo = (style.tempoSlow + style.tempoFast) / 2
        let seconds = pacing.seconds(atTempo: tempo) / Double(rawFrames)
        return Swift.max(Int((seconds * Double(frameRate)).rounded()), 1)
    }

    /// A trajectory that collapses: a helix whose radius shrinks, so the metrics move and the
    /// score has something to say about it.
    static func trajectory(rawFrames: Int = 6, framesPerRaw: Int = 4,
                           residues n: Int = 16) -> ([FoldFrame], [AminoAcid]) {
        var frames: [FoldFrame] = []
        var index = 0
        for raw in 0..<rawFrames {
            let t = Float(raw) / Float(Swift.max(rawFrames - 1, 1))
            for sub in 0..<framesPerRaw {
                let radius = 6 - 3.5 * t
                let ca = (0..<n).map { i -> SIMD3<Float> in
                    let a = Float(i) * 1.75
                    return SIMD3(radius * cos(a), radius * sin(a), Float(i) * 1.5)
                }
                let backbone = ca.map { BackboneResidue(n: $0, ca: $0, c: $0, o: $0) }
                let confidence = (0..<n).map { _ in 30 + 60 * t }
                frames.append(FoldFrame(
                    index: index, recycle: 0, blockIndex: raw, backbone: backbone,
                    pLDDT: confidence,
                    secondaryStructure: (0..<n).map {
                        _ in SSAssignment(structure: .helix, confidence: 1)
                    },
                    newContacts: sub == 0 && raw > 0
                        ? [ContactEvent(i: raw, j: raw + 8, distance: 7,
                                        isHydrophobicPair: raw.isMultiple(of: 2))]
                        : [],
                    radiusOfGyration: radius * 1.6,
                    meanPLDDT: 30 + 60 * t,
                    isInterpolated: sub != 0))
                index += 1
            }
        }
        let codes = Array("ACDEFGHIKLMNPQRSTVWY")
        let acids = (0..<n).map { AminoAcid(code: codes[$0 % codes.count]) }
        return (frames, acids)
    }

    /// The repository's own style directory, found by walking up from this source file.
    ///
    /// `FoldAudioTests` has the same helper, but a test target cannot see another's types -
    /// so this is four lines of duplication rather than a shared fixture nobody can reach.
    static var stylesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "Apps/Shared/Resources/Styles")
    }

    static var style: StyleProfile {
        get throws {
            let loaded = try StyleLibrary.profiles(in: stylesDirectory)
            return try #require(loaded["fantasy"])
        }
    }

    @MainActor
    @Test("a trajectory becomes a film with a picture and a soundtrack")
    func exportsAFilm() async throws {
        let url = FilmWriterTests.temporaryURL("export")
        defer { try? FileManager.default.removeItem(at: url) }

        let style = try Self.style
        var options = FilmExporter.Options()
        options.size = OffscreenStage.Size(width: 480, height: 270)
        options.frameRate = 24
        let (frames, residues) = Self.trajectory(
            rawFrames: 4,
            framesPerRaw: Self.framesPerReadout(rawFrames: 4, frameRate: options.frameRate,
                                                style: style))
        let summary = try await FilmExporter(options: options)
            .export(frames: frames, residues: residues, style: style, to: url)

        #expect(summary.frames >= frames.count)
        #expect(summary.bars > 0, "the film has no music in it")

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.count == 1, "the film is silent")

        // The soundtrack is sound, not a correctly-formatted silence.
        let level = try await FilmWriterTests.audioLevel(of: asset)
        #expect(level > 0.005, "the film's audio is silent (RMS \(level))")

        let dimensions = try await video[0].load(.naturalSize)
        #expect(Int(dimensions.width) == 480)
        #expect(Int(dimensions.height) == 270)
    }

    @MainActor
    @Test("the picture and the sound agree about how long the piece is")
    func pictureAndSoundAgree() async throws {
        let url = FilmWriterTests.temporaryURL("drift")
        defer { try? FileManager.default.removeItem(at: url) }

        let style = try Self.style
        var options = FilmExporter.Options()
        options.size = OffscreenStage.Size(width: 320, height: 180)
        options.frameRate = 30
        let (frames, residues) = Self.trajectory(
            rawFrames: 6,
            framesPerRaw: Self.framesPerReadout(rawFrames: 6, frameRate: options.frameRate,
                                                style: style))
        let summary = try await FilmExporter(options: options)
            .export(frames: frames, residues: residues, style: style, to: url)

        // **This is the criterion that matters and the one nothing else checks.** The frames
        // are paced by the renderer and the bars by the score, and they are computed from the
        // same pacing - so if they disagree by much, one of the two clocks has drifted from
        // the rule they are both supposed to follow.
        #expect(summary.videoSeconds > 0)
        #expect(summary.audioSeconds > 0)
        // The picture covers the sound: the last frame is held while the cadence rings out,
        // so a player never runs out of video before it runs out of music.
        #expect(summary.videoSeconds >= summary.audioSeconds - 1.0 / 30,
                "picture \(summary.videoSeconds) s against sound \(summary.audioSeconds) s")
        #expect(summary.drift < 1.0,
                "picture \(summary.videoSeconds) s against sound \(summary.audioSeconds) s")
    }

    @MainActor
    @Test("frames paced by some other rule are refused, not silently filmed")
    func mispacedFramesAreRefused() async throws {
        let url = FilmWriterTests.temporaryURL("mispaced")
        defer { try? FileManager.default.removeItem(at: url) }
        // Four frames per readout, which is what a caller reaching for a round number would
        // pick: a four-second picture against a forty-seven-second soundtrack.
        let (frames, residues) = Self.trajectory(rawFrames: 24, framesPerRaw: 5)
        var options = FilmExporter.Options()
        options.size = OffscreenStage.Size(width: 240, height: 136)
        options.frameRate = 30
        await #expect(throws: FilmWriter.Failure.self) {
            _ = try await FilmExporter(options: options)
                .export(frames: frames, residues: residues, style: try Self.style, to: url)
        }
    }

    @MainActor
    @Test("an empty trajectory is refused rather than writing an empty file")
    func emptyTrajectoryIsRefused() async throws {
        let url = FilmWriterTests.temporaryURL("empty")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: FilmWriter.Failure.self) {
            _ = try await FilmExporter().export(frames: [], residues: [],
                                                style: try Self.style, to: url)
        }
    }

    @MainActor
    @Test("progress runs from nothing to all of it")
    func progressIsReported() async throws {
        let url = FilmWriterTests.temporaryURL("progress")
        defer { try? FileManager.default.removeItem(at: url) }
        let style = try Self.style
        var options = FilmExporter.Options()
        options.size = OffscreenStage.Size(width: 240, height: 136)
        options.frameRate = 24
        let (frames, residues) = Self.trajectory(
            rawFrames: 3,
            framesPerRaw: Self.framesPerReadout(rawFrames: 3, frameRate: options.frameRate,
                                                style: style))
        var reported: [Double] = []
        _ = try await FilmExporter(options: options)
            .export(frames: frames, residues: residues, style: style, to: url) {
                reported.append($0)
            }
        // Progress is reported per supplied frame; the held tail is not part of the fold.
        #expect(reported.count == frames.count)
        #expect(reported.first ?? 0 > 0)
        #expect(abs((reported.last ?? 0) - 1) < 0.001, "progress never reached the end")
        // Monotonic, so a progress bar never goes backwards.
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 < $1 })
    }
}
