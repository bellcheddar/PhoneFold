import Testing
import Foundation
import CryptoKit
@testable import FoldAudio
import FoldCore
import FoldEngine

/// The offline render: PLAN.md's Phase 3 gate, on real trajectories.
///
/// "Identical audio output hash for the same sequence across three runs" and "offline render
/// completes with no clipping; LUFS within target range."
@Suite("Offline render")
struct OfflineRenderTests {

    static func hash(_ result: OfflineRender.Result) -> String {
        var digest = SHA256()
        for value in result.left { withUnsafeBytes(of: value.bitPattern) { digest.update(data: $0) } }
        for value in result.right { withUnsafeBytes(of: value.bitPattern) { digest.update(data: $0) } }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func score(_ name: String, engine: FoldingEngine? = nil,
                      steps: Int? = nil) async throws
        -> (score: [ScoreMoment], residues: Int, style: StyleProfile) {
        let style = try SonifierTests.style
        let url = TrajectoryScoreTests.trajectoryDirectory.appending(path: "\(name).pftraj")
        var bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        if let engine {
            (bundle, _) = try await TrajectoryScoreTests.liveFold(name, engine: engine,
                                                                  steps: steps)
        }
        let frames = try await TrajectoryScoreTests.frames(for: bundle)
        return (Sonifier.score(style: style, residues: bundle.residues, frames: frames),
                bundle.residues.count, style)
    }

    // MARK: - The gate

    @Test("the same protein renders to the same audio three times")
    func renderIsDeterministic() async throws {
        let input = try await Self.score("ubiquitin")
        let renderer = OfflineRender()
        let hashes = (0..<3).map { _ in
            Self.hash(renderer.render(input.score, style: input.style,
                                      residueCount: input.residues))
        }
        // PLAN.md's gate, and the promise the app makes: the same protein always yields the
        // same piece.
        #expect(hashes[0] == hashes[1])
        #expect(hashes[1] == hashes[2])
    }

    @Test("a rendered piece never clips")
    func renderNeverClips() async throws {
        let renderer = OfflineRender()
        for name in ["trp_cage", "ubiquitin", "lysozyme", "gfp", "beta2ar_7tm"] {
            let input = try await Self.score(name)
            let result = renderer.render(input.score, style: input.style,
                                         residueCount: input.residues)
            #expect(result.peak < 1.0, "\(name) peaked at \(result.peak)")
            #expect(result.peak > 0.01, "\(name) rendered near silence")
            let finite = result.left.allSatisfy { $0.isFinite }
                && result.right.allSatisfy { $0.isFinite }
            #expect(finite, "\(name) rendered a non-finite sample")
            #expect(result.refusedNotes == 0, "\(name) refused \(result.refusedNotes) notes")
        }
    }

    @Test("the limiter guarantees it, rather than the gain happening to be low enough")
    func limiterIsGuaranteed() {
        // Transparent below the knee.
        #expect(ScorePlayer.softClip(0.5) == 0.5)
        #expect(ScorePlayer.softClip(-0.5) == -0.5)
        // And strictly inside the rails above it, whatever is thrown at it.
        for value in [Float(1), 2, 10, 1_000, -1, -2, -10, -1_000] {
            let clipped = ScorePlayer.softClip(value)
            #expect(abs(clipped) < 1.0, "\(value) clipped to \(clipped)")
            #expect(clipped.sign == value.sign)
        }
    }

    @Test("a rendered piece lands in a usable loudness range")
    func loudnessIsInRange() async throws {
        let renderer = OfflineRender()
        let input = try await Self.score("lysozyme")
        let result = renderer.render(input.score, style: input.style,
                                     residueCount: input.residues)
        // Broadcast and streaming targets sit between -23 and -14 LUFS. A piece that arrives
        // far below that is not quiet by intent, it is a mixing fault; far above it and the
        // limiter is doing the composing.
        #expect(result.loudness > -30, "rendered at \(result.loudness) LUFS")
        #expect(result.loudness < -8, "rendered at \(result.loudness) LUFS")
    }

    // MARK: - Loudness

    @Test("loudness tracks level, and silence is not a number")
    func loudnessBehavesLikeLoudness() {
        let rate = 48_000.0
        func sine(amplitude: Float, seconds: Double = 3) -> [Float] {
            (0..<Int(seconds * rate)).map {
                amplitude * Float(sin(2 * .pi * 1_000 * Double($0) / rate))
            }
        }
        let quiet = OfflineRender.integratedLoudness(left: sine(amplitude: 0.1),
                                                     right: sine(amplitude: 0.1),
                                                     sampleRate: rate)
        let loud = OfflineRender.integratedLoudness(left: sine(amplitude: 0.2),
                                                    right: sine(amplitude: 0.2),
                                                    sampleRate: rate)
        // Twice the amplitude is six decibels.
        #expect(abs((loud - quiet) - 6.02) < 0.1, "\(quiet) to \(loud) LUFS")

        let silence = [Float](repeating: 0, count: Int(3 * rate))
        #expect(OfflineRender.integratedLoudness(left: silence, right: silence,
                                                 sampleRate: rate) == -.infinity)

        // The K-weighting coefficients are the standard's own, at 48 kHz. At any other rate
        // they are simply wrong, so this says so rather than quietly reporting a number.
        #expect(OfflineRender.integratedLoudness(left: sine(amplitude: 0.1),
                                                 right: sine(amplitude: 0.1),
                                                 sampleRate: 44_100).isNaN)
    }

    @Test("the gate ignores the silence a piece opens with")
    func loudnessIsGated() {
        let rate = 48_000.0
        let tone = (0..<Int(3 * rate)).map {
            Float(0.2 * sin(2 * .pi * 1_000 * Double($0) / rate))
        }
        let silence = [Float](repeating: 0, count: Int(9 * rate))
        let alone = OfflineRender.integratedLoudness(left: tone, right: tone, sampleRate: rate)
        let padded = OfflineRender.integratedLoudness(left: silence + tone,
                                                      right: silence + tone, sampleRate: rate)
        // Ungated, nine seconds of silence in front of three of tone would read six decibels
        // quieter. The gating is the part usually left out, and the part that matters for a
        // piece that opens on an unfolded chain.
        #expect(abs(padded - alone) < 0.5, "\(alone) alone, \(padded) with silence in front")
    }

    // MARK: - WAV

    @Test("the WAV says what it contains, and says it correctly")
    func wavHeaderIsCorrect() {
        let frames = 1_000
        let left = (0..<frames).map { Float(sin(Double($0) * 0.1)) }
        let right = (0..<frames).map { Float(-sin(Double($0) * 0.1)) }
        let data = OfflineRender.wav(left: left, right: right, sampleRate: 48_000)

        #expect(data.count == 44 + frames * 4)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<(offset + 2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        }
        #expect(u32(4) == UInt32(36 + frames * 4))
        #expect(u16(22) == 2, "two channels")
        #expect(u32(24) == 48_000)
        #expect(u16(34) == 16, "sixteen bits a sample")
        #expect(u32(40) == UInt32(frames * 4))
    }

    @Test("full scale survives the round trip without inverting")
    func fullScaleDoesNotWrap() {
        // Scaling by 32768 makes -1.0 valid and +1.0 overflow, which shows up as a single
        // inverted sample at the loudest moment of a piece - the one place it is audible.
        let data = OfflineRender.wav(left: [1.0, -1.0, 0.5, 2.0, -2.0],
                                     right: [1.0, -1.0, 0.5, 2.0, -2.0], sampleRate: 48_000)
        let samples = data[44...].withUnsafeBytes { raw -> [Int16] in
            (0..<(raw.count / 2)).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
        #expect(samples[0] == 32_767)
        #expect(samples[2] == -32_767)
        // And a value out of range is clamped, not wrapped around to the opposite rail.
        #expect(samples[6] == 32_767)
        #expect(samples[8] == -32_767)
    }
}
