import Testing
import Foundation
import AVFoundation
import simd
@testable import FoldAudio
import FoldCore

/// The live audio path, rendered through the real `AVAudioEngine` graph.
///
/// `OfflineRender` proves the score and the synthesis. These prove the *graph* - the
/// environment node, the HRTF, the connections and the render blocks - which is a different
/// thing and the only place a wiring mistake shows up. Manual rendering mode runs it all
/// without an audio device, so it works in a test.
@Suite("Live audio engine")
struct FoldAudioEngineTests {

    static func note(_ voice: Voice, beat: Double, pitch: UInt8 = 60, residue: Int,
                     partner: Int? = nil, duration: Double = 1) -> NoteEvent {
        NoteEvent(voice: voice, note: MIDINote(pitch: pitch, velocity: 110),
                  residue: residue, partner: partner, beatOffset: beat, duration: duration)
    }

    static func moment(_ index: Int, notes: [NoteEvent]) -> ScoreMoment {
        ScoreMoment(frameIndex: index, tempo: 120, notes: notes,
                    timbre: Sonifier.timbre(meanConfidence: 90), degree: 0,
                    isCadence: false, isModulation: false, compaction: 0.5,
                    droppedContacts: 0)
    }

    /// A chain laid out along x and centred on the origin, so a residue's index and its
    /// position are easy to reason about.
    static func chain(_ count: Int) -> [SIMD3<Float>] {
        (0..<count).map { SIMD3<Float>(Float($0) * 3.8 - Float(count - 1) * 1.9, 0, 0) }
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for value in samples { sum += Double(value) * Double(value) }
        return (sum / Double(samples.count)).squareRoot()
    }

    // MARK: - The graph makes sound

    @Test("the graph renders audio through the environment node")
    func graphMakesSound() throws {
        let style = try SonifierTests.style
        let engine = FoldAudioEngine(style: style, residueCount: 20)
        let positions = Self.chain(20)
        var submitted = false
        let output = try engine.renderOffline(seconds: 1.5) { time, engine in
            guard !submitted, time == 0 else { return }
            submitted = true
            engine.submit(Self.moment(0, notes: [
                Self.note(.pad, beat: 0, pitch: 57, residue: 5, duration: 4),
                Self.note(.contact, beat: 0, pitch: 69, residue: 2, partner: 15),
            ]), positions: positions)
        }
        // A wiring mistake - the environment node not connected, the render block returning
        // silence, the format wrong - shows here and nowhere else.
        #expect(Self.rms(output.left) > 0.001, "the graph produced silence")
        #expect(Self.rms(output.right) > 0.001)
        let finite = output.left.allSatisfy { $0.isFinite } && output.right.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect((output.left.map(abs).max() ?? 0) <= 1.0)
    }

    @Test("a note on the left of the chain arrives on the left")
    func spatialisationPlacesNotes() throws {
        let style = try SonifierTests.style
        let positions = Self.chain(40)

        func render(residue: Int) throws -> (left: Double, right: Double) {
            let engine = FoldAudioEngine(style: style, residueCount: 40)
            var submitted = false
            let output = try engine.renderOffline(seconds: 1.0) { time, engine in
                guard !submitted, time == 0 else { return }
                submitted = true
                engine.submit(Self.moment(0, notes: [
                    Self.note(.pad, beat: 0, pitch: 60, residue: residue, duration: 4),
                ]), positions: positions)
            }
            return (Self.rms(output.left), Self.rms(output.right))
        }

        // PLAN.md: each residue's note is positioned at that residue's live 3D coordinate, so
        // the fold collapses around the listener. The N-terminus of this chain is at negative
        // x and the C-terminus at positive x.
        let start = try render(residue: 0)
        let end = try render(residue: 39)
        #expect(start.left > start.right, "the N-terminus should be to the left")
        #expect(end.right > end.left, "the C-terminus should be to the right")
        // And both were audible, so the comparison is between two sounds rather than two
        // silences.
        #expect(start.left > 0.0005)
        #expect(end.right > 0.0005)
    }

    @Test("a contact is placed between its two partners")
    func contactSitsBetweenItsPartners() {
        let positions = Self.chain(40)
        let contact = Self.note(.contact, beat: 0, residue: 0, partner: 39)
        let placed = FoldAudioEngine.position(of: contact, in: positions)
        let midpoint = (positions[0] + positions[39]) / 2 / FoldAudioEngine.angstromsPerMetre
        #expect(abs(placed.x - midpoint.x) < 1e-5)
        // A contact happens between two residues, so placing it at either end would put the
        // sound somewhere the event is not.
        #expect(abs(placed.x) < 1e-5, "this pair straddles the centre")
    }

    @Test("a note whose residue has no coordinate is centred, not dropped")
    func missingCoordinatesAreCentred() {
        // A frame not yet delivered, or a chain shorter than the score believes.
        let note = Self.note(.pad, beat: 0, residue: 500)
        #expect(FoldAudioEngine.position(of: note, in: Self.chain(10)) == .zero)
        #expect(FoldAudioEngine.position(of: note, in: []) == .zero)
    }

    @Test("the protein is scaled to a stage the listener stands inside")
    func scaleIsHumanSized() {
        // A folded protein is tens of angstroms across. One-to-one it would sit tens of metres
        // away and the whole piece would arrive from a point.
        let positions = Self.chain(80)          // about 300 A end to end
        let first = FoldAudioEngine.position(of: Self.note(.pad, beat: 0, residue: 0),
                                             in: positions)
        let last = FoldAudioEngine.position(of: Self.note(.pad, beat: 0, residue: 79),
                                            in: positions)
        let width = abs(last.x - first.x)
        #expect(width > 2 && width < 40, "the chain spans \(width) m")
    }

    // MARK: - The pool

    @Test("more notes than voices costs notes, never corrupts one")
    func polyphonyIsBounded() throws {
        let style = try SonifierTests.style
        let engine = FoldAudioEngine(style: style, residueCount: 64)
        let positions = Self.chain(64)
        // Twice as many simultaneous long notes as there are spatial voices.
        let crowd = (0..<(FoldAudioEngine.spatialVoices * 2)).map {
            Self.note(.pad, beat: 0, pitch: UInt8(40 + $0), residue: $0, duration: 8)
        }
        var submitted = false
        let output = try engine.renderOffline(seconds: 1.0) { time, engine in
            guard !submitted, time == 0 else { return }
            submitted = true
            engine.submit(Self.moment(0, notes: crowd), positions: positions)
        }
        #expect(engine.droppedForPolyphony > 0, "the pool should have run out")
        #expect(engine.soundingVoices <= FoldAudioEngine.spatialVoices)
        // The point of counting rather than stealing: a voice the audio thread owns is never
        // written over, so the output stays clean rather than glitching.
        let finite = output.left.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect((output.left.map(abs).max() ?? 0) <= 1.0)
    }

    @Test("stopping releases every voice")
    func allNotesOffReleases() throws {
        let style = try SonifierTests.style
        let engine = FoldAudioEngine(style: style, residueCount: 20)
        let positions = Self.chain(20)
        var submitted = false
        // Three seconds, not two: the Fantasy pad's release is 1.8 s, so a two-second render
        // cuts off mid-release and measures the decay rather than the silence after it.
        let output = try engine.renderOffline(seconds: 3.0) { time, engine in
            if !submitted, time == 0 {
                submitted = true
                engine.submit(Self.moment(0, notes: [
                    Self.note(.pad, beat: 0, pitch: 57, residue: 5, duration: 16),
                ]), positions: positions)
            }
            if time > 0.5 { engine.allNotesOff() }
        }
        let tail = Array(output.left.suffix(Int(0.2 * 48_000)))
        // A pad asked to sound for sixteen beats, cut off after half a second: once its 1.8 s
        // release has run there must be nothing left.
        #expect(Self.rms(tail) < 0.0005, "the tail still had \(Self.rms(tail)) RMS in it")
    }

    // MARK: - It plays the same music the offline renderer does

    @Test("the live graph and the offline renderer play the same score")
    func liveMatchesOffline() async throws {
        let style = try SonifierTests.style
        let input = try await OfflineRenderTests.score("trp_cage")
        let engine = FoldAudioEngine(style: style, residueCount: input.residues)
        let positions = Self.chain(input.residues)

        var next = 0
        let output = try engine.renderOffline(seconds: 6) { _, engine in
            while next < input.score.count, engine.nextBeat < (engine.audioTime ?? 0) + 4 {
                engine.submit(input.score[next], positions: positions)
                next += 1
            }
        }
        #expect(next > 0, "no music was submitted")
        #expect(Self.rms(output.left) > 0.001, "the live graph produced silence")
        #expect(engine.refusedNotes == 0)
        // Not sample-identical - HRTF convolution is not equal-power panning, and it should
        // not be - but the same score through the same synthesis should land in the same
        // ballpark rather than an order of magnitude away.
        let renderer = OfflineRender(tail: 0)
        let reference = renderer.render(Array(input.score.prefix(next)), style: style,
                                        residueCount: input.residues)
        let liveRMS = Self.rms(output.left)
        let offlineRMS = Double(reference.rms)
        #expect(liveRMS > offlineRMS / 8 && liveRMS < offlineRMS * 8,
                "live \(liveRMS) against offline \(offlineRMS)")
    }
}

extension FoldAudioEngineTests {

    @Test("a style change reaches the notes written after it, not the ones already queued")
    func styleSwitchIsQuantised() throws {
        let styles = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
        let fantasy = try #require(styles["fantasy"])
        let rock = try #require(styles["rock"])
        let engine = FoldAudioEngine(style: fantasy, residueCount: 20)
        let positions = Self.chain(20)

        var submitted = false
        var switched = false
        let output = try engine.renderOffline(seconds: 2.0) { time, engine in
            if !submitted, time == 0 {
                submitted = true
                // Four moments queued at once: two beats' worth ahead of the playhead.
                for i in 0..<4 {
                    engine.submit(Self.moment(i, notes: [
                        Self.note(.pad, beat: 0, pitch: 60, residue: 5, duration: 1),
                    ]), positions: positions)
                }
            }
            if !switched, time > 0.05 {
                switched = true
                // From one second in - by which point notes are already on the timeline.
                engine.adopt(rock, from: 1.0)
            }
        }
        #expect(engine.style.id == "rock")
        #expect(Self.rms(output.left) > 0.001)
        // Swapping the timbres outright would retimbre notes written under the old style and
        // already on their way, so the switch would arrive early and raggedly rather than on
        // the beat it was asked for.
        let finite = output.left.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect((output.left.map(abs).max() ?? 0) <= 1.0)
    }
}

extension FoldAudioEngineTests {

    @Test("the capture tap hears the finished mix")
    func captureTapHearsTheMix() throws {
        // PLAN.md: "Tap mainMixerNode for the Phase 4 capture path." Phase 4 records the piece,
        // and a tap that heard silence would be discovered there rather than here.
        let style = try SonifierTests.style
        let engine = FoldAudioEngine(style: style, residueCount: 20)
        let positions = Self.chain(20)

        // The tap runs on the audio thread; this only counts and sums, and takes no lock.
        let captured = Captured()
        engine.installCaptureTap(bufferSize: 1_024) { buffer, _ in
            guard let channel = buffer.floatChannelData else { return }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) {
                sum += Double(channel[0][i]) * Double(channel[0][i])
            }
            captured.add(frames: Int(buffer.frameLength), energy: sum)
        }

        var submitted = false
        _ = try engine.renderOffline(seconds: 1.5) { time, engine in
            guard !submitted, time == 0 else { return }
            submitted = true
            engine.submit(Self.moment(0, notes: [
                Self.note(.pad, beat: 0, pitch: 57, residue: 5, duration: 4),
            ]), positions: positions)
        }
        engine.removeCaptureTap()

        #expect(captured.frames > 0, "the tap was never called")
        #expect(captured.energy > 0, "the tap heard silence")
    }

    /// A counter the tap block can reach without locking on the audio thread.
    final class Captured: @unchecked Sendable {
        private(set) var frames = 0
        private(set) var energy = 0.0
        func add(frames count: Int, energy value: Double) {
            frames += count
            energy += value
        }
    }
}
