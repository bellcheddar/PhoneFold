import Testing
import Foundation
@testable import FoldAudio

/// The synthesiser: oscillators, envelopes and a fixed voice pool.
@Suite("Synthesiser")
struct SynthesiserTests {

    static let sampleRate = 48_000.0

    static func spec(_ waveform: VoiceSpec.Waveform = .sine, attack: Double = 0.002,
                     decay: Double = 0.05, sustain: Double = 1, release: Double = 0.05,
                     harmonics: [Double] = [], gain: Double = 1,
                     detune: Double = 0) -> RenderVoiceSpec {
        var spec = VoiceSpec()
        spec.waveform = waveform
        spec.attack = attack
        spec.decay = decay
        spec.sustain = sustain
        spec.release = release
        spec.harmonics = harmonics
        spec.gain = gain
        spec.detuneCents = detune
        return RenderVoiceSpec(spec)
    }

    static let clean = TimbreState(cutoff: 20_000, detuneCents: 0, reverb: 0)

    /// Render one voice for a number of seconds and hand back the left channel.
    static func render(_ voice: inout SynthVoice, seconds: Double) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                voice.render(left: l, right: r, range: 0..<frames, sampleRate: sampleRate)
            }
        }
        return left
    }

    /// Frequency estimated from zero crossings, which is exact enough for a clean tone and
    /// needs no transform.
    static func frequency(_ samples: [Float], seconds: Double) -> Double {
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / seconds
    }

    // MARK: - Oscillators

    @Test("a sine voice sounds at the frequency it was given")
    func sineIsAtPitch() {
        var voice = SynthVoice()
        voice.start(frequency: 440, velocity: 1, spec: Self.spec(),
                    timbre: Self.clean, sampleRate: Self.sampleRate,
                    tag: 0, residue: 0, partner: -1)
        let samples = Self.render(&voice, seconds: 1)
        #expect(abs(Self.frequency(samples, seconds: 1) - 440) < 2)
    }

    @Test("every waveform makes sound, and none of it leaves the rails")
    func everyWaveformIsBounded() {
        for waveform in VoiceSpec.Waveform.allCases {
            var voice = SynthVoice()
            voice.start(frequency: 220, velocity: 1, spec: Self.spec(waveform, gain: 1),
                        timbre: Self.clean, sampleRate: Self.sampleRate,
                        tag: 0, residue: 0, partner: -1)
            let samples = Self.render(&voice, seconds: 0.5)
            let peak = samples.map(abs).max() ?? 0
            #expect(peak > 0.05, "\(waveform) produced nothing")
            // A single voice at full velocity and unit gain must stay inside the rails, or the
            // mix has no headroom before it has begun.
            #expect(peak <= 1.05, "\(waveform) peaked at \(peak)")
        }
    }

    @Test("the harmonic stack is normalised, so a rich voice is not a loud one")
    func harmonicStackIsNormalised() {
        var plain = SynthVoice()
        plain.start(frequency: 220, velocity: 1, spec: Self.spec(.sine),
                    timbre: Self.clean, sampleRate: Self.sampleRate,
                    tag: 0, residue: 0, partner: -1)
        var stacked = SynthVoice()
        stacked.start(frequency: 220, velocity: 1,
                      spec: Self.spec(.sine, harmonics: [1, 0.5, 0.3, 0.2]),
                      timbre: Self.clean, sampleRate: Self.sampleRate,
                      tag: 0, residue: 0, partner: -1)
        let a = Self.render(&plain, seconds: 0.3).map(abs).max() ?? 0
        let b = Self.render(&stacked, seconds: 0.3).map(abs).max() ?? 0
        // Without normalisation the four-partial stack would be twice as loud as the sine and
        // the pad would drown the piece purely for being the richest voice.
        #expect(b < a * 1.4)
        #expect(b > a * 0.4)
    }

    @Test("PolyBLEP corrects only at the discontinuity")
    func polyBLEPIsLocal() {
        let dt = 0.01
        // In the middle of the cycle a saw is already a straight line and needs no correction;
        // a correction applied there would be distortion rather than anti-aliasing.
        #expect(SynthVoice.polyBLEP(0.5, dt) == 0)
        #expect(SynthVoice.polyBLEP(0.25, dt) == 0)
        // At the step it is -1 either side, which is what cancels the jump.
        #expect(abs(SynthVoice.polyBLEP(0, dt) - -1) < 1e-12)
        #expect(abs(SynthVoice.polyBLEP(1 - 1e-12, dt) - 1) < 1e-6)
    }

    @Test("anti-aliasing removes energy a naive saw folds back")
    func polyBLEPReducesAliasing() {
        // A sawtooth an octave below Nyquist has partials far above it. Without correction
        // those fold down as inharmonic tones - worst in exactly the high register the sheet
        // figure plays in.
        var corrected = SynthVoice()
        corrected.start(frequency: 6_000, velocity: 1, spec: Self.spec(.sawtooth),
                        timbre: Self.clean, sampleRate: Self.sampleRate,
                        tag: 0, residue: 0, partner: -1)
        let samples = Self.render(&corrected, seconds: 0.2)
        // A naive saw at 6 kHz has a zero-crossing rate wandering far from its own frequency
        // as the aliases beat against it; the corrected one stays near it.
        let measured = Self.frequency(samples, seconds: 0.2)
        #expect(abs(measured - 6_000) < 600, "measured \(measured) Hz")
    }

    // MARK: - Envelope

    @Test("the envelope rises, holds and falls where it says it will")
    func envelopeFollowsItsStages() {
        var envelope = Envelope(Self.spec(attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.2))
        let dt = 1 / Self.sampleRate
        var level = 0.0
        // Attack: full by 100 ms. A sample or two over the boundary, because summing dt four
        // thousand eight hundred times lands a hair short of it.
        for _ in 0...Int(0.1 * Self.sampleRate) { level = envelope.next(sampleInterval: dt) }
        #expect(abs(level - 1) < 0.01)
        // Decay to the sustain level by 200 ms.
        for _ in 0...Int(0.1 * Self.sampleRate) { level = envelope.next(sampleInterval: dt) }
        #expect(abs(level - 0.5) < 0.01)
        #expect(envelope.stage == .sustain)
        // Sustain holds indefinitely.
        for _ in 0..<Int(0.5 * Self.sampleRate) { level = envelope.next(sampleInterval: dt) }
        #expect(abs(level - 0.5) < 0.001)
        // Release falls to nothing.
        envelope.beginRelease()
        for _ in 0...Int(0.2 * Self.sampleRate) { level = envelope.next(sampleInterval: dt) }
        #expect(envelope.isFinished)
        #expect(level == 0)
    }

    @Test("a pluck finishes on its own and gives its slot back")
    func pluckReleasesItself() {
        // A voice whose sustain is zero has finished when it has decayed. Holding it at
        // silence would occupy a slot another note wants, and thirty-two plucks would silence
        // the piece.
        var voice = SynthVoice()
        voice.start(frequency: 440, velocity: 1,
                    spec: Self.spec(attack: 0.002, decay: 0.05, sustain: 0),
                    timbre: Self.clean, sampleRate: Self.sampleRate,
                    tag: 7, residue: 0, partner: -1)
        _ = Self.render(&voice, seconds: 0.2)
        #expect(!voice.isActive)
    }

    @Test("no note starts with a click")
    func attackIsNeverInstant() {
        // A zero attack steps from silence to full amplitude in one sample, which is a click.
        var spec = VoiceSpec()
        spec.attack = 0
        #expect(RenderVoiceSpec(spec).attack >= 0.002)

        var voice = SynthVoice()
        voice.start(frequency: 440, velocity: 1, spec: RenderVoiceSpec(spec),
                    timbre: Self.clean, sampleRate: Self.sampleRate,
                    tag: 0, residue: 0, partner: -1)
        let samples = Self.render(&voice, seconds: 0.05)
        var largestStep: Float = 0
        for i in 1..<samples.count {
            largestStep = Swift.max(largestStep, abs(samples[i] - samples[i - 1]))
        }
        // At 440 Hz and 48 kHz a clean sine moves at most about 0.06 per sample.
        #expect(largestStep < 0.15, "largest single-sample step was \(largestStep)")
    }

    // MARK: - Panning

    @Test("a note is placed where its residue is")
    func panPlacesTheNote() {
        func channels(pan: Double) -> (Float, Float) {
            var voice = SynthVoice()
            voice.start(frequency: 440, velocity: 1, spec: Self.spec(),
                        timbre: Self.clean, sampleRate: Self.sampleRate,
                        tag: 0, residue: 0, partner: -1, pan: pan)
            let frames = 4_800
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    voice.render(left: l, right: r, range: 0..<frames,
                                 sampleRate: Self.sampleRate)
                }
            }
            return (left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        }
        let left = channels(pan: -1)
        let centre = channels(pan: 0)
        let right = channels(pan: 1)
        #expect(left.0 > left.1 * 20)
        #expect(right.1 > right.0 * 20)
        #expect(abs(centre.0 - centre.1) < 0.01)
        // Equal power: the centre must not be quieter than the sides, or a fold collapsing
        // toward the middle would sound like the music receding as the protein arrives.
        let sideEnergy = left.0 * left.0 + left.1 * left.1
        let centreEnergy = centre.0 * centre.0 + centre.1 * centre.1
        #expect(abs(sideEnergy - centreEnergy) < 0.05 * sideEnergy)
    }

    // MARK: - The pool

    @Test("the pool is fixed and steals rather than growing")
    func poolStealsWhenFull() {
        var synth = Synthesiser(polyphony: 4)
        var tags: [Int] = []
        for i in 0..<4 {
            tags.append(synth.noteOn(frequency: 220 * Double(i + 1), velocity: 1,
                                     spec: Self.spec(sustain: 1), timbre: Self.clean,
                                     sampleRate: Self.sampleRate, residue: i))
        }
        #expect(synth.activeVoices == 4)
        // A fifth note steals the oldest, which is the one nearest to finishing. Stealing the
        // newest would cut off the note that just arrived, which is the audible one.
        let fifth = synth.noteOn(frequency: 1_760, velocity: 1, spec: Self.spec(sustain: 1),
                                 timbre: Self.clean, sampleRate: Self.sampleRate, residue: 9)
        #expect(synth.activeVoices == 4, "the pool must not grow")
        #expect(synth.stolenVoices == 1)
        #expect(fifth >= 0)
        #expect(synth.residue(ofVoice: 0) != nil)
    }

    @Test("a low-confidence note is dull and detuned, not silent")
    func lowConfidenceIsMurkyNotMissing() {
        // PLAN.md asks for low confidence to sound murky and out of tune. An earlier version
        // squared the velocity on top of the filter and the voice gain, and the first
        // twenty-four seconds of a fold rendered at 0.001 RMS - missing, not murky.
        func energy(confidence: Float) -> Double {
            var voice = SynthVoice()
            voice.start(frequency: 440,
                        velocity: Double(Sonifier.velocity(confidence: confidence)) / 127,
                        spec: Self.spec(.triangle, harmonics: [1, 0.4, 0.2], gain: 0.35),
                        timbre: Sonifier.timbre(meanConfidence: confidence),
                        sampleRate: Self.sampleRate, tag: 0, residue: 0, partner: -1)
            let samples = Self.render(&voice, seconds: 0.4)
            var sum = 0.0
            for s in samples { sum += Double(s) * Double(s) }
            return (sum / Double(samples.count)).squareRoot()
        }
        let murky = energy(confidence: 0)
        let clear = energy(confidence: 100)
        #expect(murky > 0.01, "a low-confidence note rendered at \(murky) RMS - inaudible")
        #expect(murky < clear, "and it should still be quieter and duller than a resolved one")
        #expect(clear / murky < 12, "but not by more than an order of magnitude")
    }
}
