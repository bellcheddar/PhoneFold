import Foundation

/// A voice's timbre, flattened into something a render callback may touch.
///
/// `VoiceSpec` holds its harmonics in an `Array`, which is a reference type: reading it on the
/// audio thread is a retain and release, and a copy would be an allocation. This is the same
/// description with the array replaced by a fixed-width vector, so a render block can hold one
/// by value and never touch the heap.
///
/// Eight harmonics is not a limitation in practice - the eighth partial of a 440 Hz note is
/// 3.5 kHz, and above that the additive stack is doing less for the sound than the filter is.
public struct RenderVoiceSpec: Sendable, Hashable {
    public static let maximumHarmonics = 8

    public var waveform: VoiceSpec.Waveform
    public var harmonicCount: Int
    public var harmonics: SIMD8<Double>
    /// Sum of the harmonic amplitudes, so the stack can be normalised without a loop.
    public var harmonicSum: Double
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    public var detuneCents: Double
    public var fmRatio: Double
    public var fmIndex: Double
    public var gain: Double

    public init(_ spec: VoiceSpec) {
        waveform = spec.waveform
        var vector = SIMD8<Double>()
        let taken = Swift.min(spec.harmonics.count, Self.maximumHarmonics)
        for i in 0..<taken { vector[i] = spec.harmonics[i] }
        harmonicCount = taken
        harmonics = vector
        var sum = 0.0
        for i in 0..<taken { sum += abs(vector[i]) }
        harmonicSum = sum
        // A note with no attack at all clicks, because the waveform steps from silence to full
        // amplitude in one sample. Two milliseconds is inaudible as an attack and removes it.
        attack = Swift.max(spec.attack, 0.002)
        decay = Swift.max(spec.decay, 0)
        sustain = Swift.min(Swift.max(spec.sustain, 0), 1)
        release = Swift.max(spec.release, 0.005)
        detuneCents = spec.detuneCents
        fmRatio = Swift.max(spec.fmRatio, 0)
        fmIndex = Swift.max(spec.fmIndex, 0)
        gain = Swift.max(spec.gain, 0)
    }
}

/// A linear ADSR envelope.
///
/// Linear rather than exponential deliberately: every segment's level at every moment is
/// arithmetic a test can predict exactly, and the difference is not audible under a pad's
/// nine-hundred-millisecond attack. Where it would matter - a pluck's decay - the low-pass
/// does more shaping than the curve of the envelope does.
public struct Envelope: Sendable, Hashable {
    public enum Stage: Sendable, Hashable { case attack, decay, sustain, release, finished }

    public private(set) var stage: Stage = .attack
    public private(set) var level: Double = 0
    private var elapsed: Double = 0
    private var releaseFrom: Double = 0

    let attack: Double
    let decay: Double
    let sustainLevel: Double
    let release: Double

    public init(_ spec: RenderVoiceSpec) {
        attack = spec.attack
        decay = spec.decay
        sustainLevel = spec.sustain
        release = spec.release
    }

    public var isFinished: Bool { stage == .finished }

    /// Advance one sample and return the new level.
    public mutating func next(sampleInterval dt: Double) -> Double {
        switch stage {
        case .attack:
            elapsed += dt
            level = attack > 0 ? Swift.min(elapsed / attack, 1) : 1
            if elapsed >= attack { stage = .decay; elapsed = 0; level = 1 }
        case .decay:
            elapsed += dt
            let t = decay > 0 ? Swift.min(elapsed / decay, 1) : 1
            level = 1 + (sustainLevel - 1) * t
            if elapsed >= decay {
                elapsed = 0
                // A voice whose sustain is zero is a pluck: it has finished when it decays,
                // and holding it at silence would occupy a slot that another note wants.
                stage = sustainLevel <= 0 ? .finished : .sustain
                level = sustainLevel
            }
        case .sustain:
            level = sustainLevel
        case .release:
            elapsed += dt
            let t = release > 0 ? Swift.min(elapsed / release, 1) : 1
            level = releaseFrom * (1 - t)
            if elapsed >= release { stage = .finished; level = 0 }
        case .finished:
            level = 0
        }
        return level
    }

    public mutating func beginRelease() {
        guard stage != .release, stage != .finished else { return }
        releaseFrom = level
        elapsed = 0
        stage = .release
    }
}

/// One sounding note.
///
/// A value type with no references in it at all, so a pool of them is one flat allocation and
/// the render loop touches nothing but its own memory.
public struct SynthVoice: Sendable {

    public private(set) var isActive = false
    /// Which note this voice was allocated to, so the scheduler can release the right one.
    public private(set) var tag: Int = -1
    /// The residue this note came from, which is what positions it in space.
    public private(set) var residue: Int = -1
    public private(set) var partner: Int = -1

    private var spec = RenderVoiceSpec(VoiceSpec())
    private var envelope = Envelope(RenderVoiceSpec(VoiceSpec()))
    private var frequency: Double = 440
    private var amplitude: Double = 0
    private var phase: Double = 0
    private var detunedPhase: Double = 0
    private var modulatorPhase: Double = 0
    private var detuneRatio: Double = 1
    /// One-pole low-pass state and coefficient, from the moment's timbre.
    private var filterState: Double = 0
    private var filterCoefficient: Double = 1
    /// -1 hard left, 0 centre, 1 hard right. Set from where the note's residue is in space.
    private var leftGain: Double = 0.7071
    private var rightGain: Double = 0.7071

    public init() {}

    public mutating func start(frequency: Double, velocity: Double, spec: RenderVoiceSpec,
                              timbre: TimbreState, sampleRate: Double,
                              tag: Int, residue: Int, partner: Int, pan: Double = 0) {
        self.spec = spec
        envelope = Envelope(spec)
        self.frequency = Swift.max(frequency, 0.01)
        // Velocity to amplitude linearly, **not** by a square law.
        //
        // Squaring it was measured and reverted. A structure-based fold opens at near-zero
        // confidence, which is velocity 30 of 127; squared that is -25 dB, and on top of the
        // low-pass and the voice's own gain the first twenty-four seconds of a villin fold
        // rendered at 0.001 RMS against the same style's 0.115 elsewhere. PLAN.md asks for low
        // confidence to sound *murky and out of tune*, which the filter and the detune do.
        // Inaudible is not murky, it is missing.
        amplitude = Swift.min(Swift.max(velocity, 0), 1)
        phase = 0
        detunedPhase = 0
        modulatorPhase = 0
        // The style's own detune, plus whatever low confidence adds on top.
        detuneRatio = pow(2, (spec.detuneCents + timbre.detuneCents) / 1200)
        filterState = 0
        filterCoefficient = Self.onePoleCoefficient(cutoff: timbre.cutoff, sampleRate: sampleRate)
        // Equal power, so a note sweeping across the stage keeps its loudness. A linear pan
        // dips by 3 dB in the middle, which on a fold that collapses toward the centre would
        // sound like the music receding exactly as the protein arrives.
        let angle = (Swift.min(Swift.max(pan, -1), 1) + 1) * .pi / 4
        leftGain = cos(angle)
        rightGain = sin(angle)
        self.tag = tag
        self.residue = residue
        self.partner = partner
        isActive = true
    }

    public mutating func release() { envelope.beginRelease() }

    public mutating func silence() {
        isActive = false
        tag = -1
        residue = -1
        partner = -1
    }

    /// One-pole low-pass coefficient for a corner frequency.
    static func onePoleCoefficient(cutoff: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, cutoff > 0 else { return 1 }
        // Clamped below Nyquist: a cutoff above it is not a filter, it is a pass-through with
        // a coefficient that has left the stable range.
        let corner = Swift.min(cutoff, sampleRate * 0.45)
        let x = exp(-2 * .pi * corner / sampleRate)
        return 1 - x
    }

    /// PolyBLEP correction, which removes most of the aliasing a naive saw or square makes.
    ///
    /// Without it the square-wave rhythm voice, whose partials run to Nyquist by construction,
    /// folds them back down as inharmonic tones - and it is worst at high pitch, which is
    /// exactly the register the sheet figure plays in.
    static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    static func wave(_ waveform: VoiceSpec.Waveform, phase t: Double, increment dt: Double,
                     modulator: Double, index: Double) -> Double {
        switch waveform {
        case .sine:
            return sin(2 * .pi * t)
        case .triangle:
            return 4 * abs(t - 0.5) - 1
        case .sawtooth:
            return (2 * t - 1) - polyBLEP(t, dt)
        case .square:
            let naive = t < 0.5 ? 1.0 : -1.0
            var other = t + 0.5
            if other >= 1 { other -= 1 }
            return naive + polyBLEP(t, dt) - polyBLEP(other, dt)
        case .fm:
            return sin(2 * .pi * t + index * modulator)
        }
    }

    /// Sum this voice into a stereo pair. Adds rather than writes, because the pool mixes.
    public mutating func render(left: UnsafeMutableBufferPointer<Float>,
                                right: UnsafeMutableBufferPointer<Float>,
                                range: Range<Int>, sampleRate: Double) {
        guard isActive, sampleRate > 0 else { return }
        let dt = 1 / sampleRate
        let increment = frequency / sampleRate
        let detunedIncrement = frequency * detuneRatio / sampleRate
        let modulatorIncrement = frequency * spec.fmRatio / sampleRate
        let stacked = spec.harmonicCount > 0
        let normal = stacked ? 1 / Swift.max(spec.harmonicSum, 1e-9) : 1

        for i in range {
            let level = envelope.next(sampleInterval: dt)
            if envelope.isFinished { silence(); return }

            let modulator = sin(2 * .pi * modulatorPhase)
            var sample: Double
            if stacked {
                // An additive stack, and each partial gets its own aliasing correction because
                // the eighth harmonic reaches Nyquist long before the fundamental does.
                var total = 0.0
                for k in 0..<spec.harmonicCount {
                    let amplitude = spec.harmonics[k]
                    guard amplitude != 0 else { continue }
                    let multiple = Double(k + 1)
                    var partial = phase * multiple
                    partial -= partial.rounded(.down)
                    let partialIncrement = increment * multiple
                    guard partialIncrement < 0.5 else { break }   // above Nyquist
                    total += amplitude * Self.wave(spec.waveform, phase: partial,
                                                   increment: partialIncrement,
                                                   modulator: modulator, index: spec.fmIndex)
                }
                sample = total * normal
            } else {
                sample = Self.wave(spec.waveform, phase: phase, increment: increment,
                                   modulator: modulator, index: spec.fmIndex)
            }

            if spec.detuneCents != 0 || detuneRatio != 1 {
                let second = Self.wave(spec.waveform, phase: detunedPhase,
                                       increment: detunedIncrement,
                                       modulator: modulator, index: spec.fmIndex)
                sample = (sample + second) * 0.5
            }

            // One-pole low-pass: the murk that low confidence is supposed to sound like.
            filterState += filterCoefficient * (sample - filterState)

            let value = filterState * level * amplitude * spec.gain
            left[i] += Float(value * leftGain)
            right[i] += Float(value * rightGain)

            phase += increment
            if phase >= 1 { phase -= 1 }
            detunedPhase += detunedIncrement
            if detunedPhase >= 1 { detunedPhase -= 1 }
            modulatorPhase += modulatorIncrement
            if modulatorPhase >= 1 { modulatorPhase -= 1 }
        }
    }
}

/// A fixed pool of voices, and the note-on and note-off that drive them.
///
/// **Fixed, and allocated once.** Polyphony has a ceiling and the ceiling is enforced by
/// stealing the quietest voice rather than by growing the pool, because growing it would mean
/// allocating on the audio thread.
public struct Synthesiser: Sendable {

    /// How many notes may sound at once.
    ///
    /// Sixteen contact onsets is the sonifier's own cap for one bar, and the pad and the two
    /// texture voices add up to about a dozen more, so thirty-two covers a full bar overlapping
    /// with the tail of the one before it.
    public static let polyphony = 32

    private var voices: [SynthVoice]
    private var nextTag = 0
    /// Notes that could not be started because every voice was busy and none could be stolen.
    public private(set) var stolenVoices = 0

    public init(polyphony: Int = Synthesiser.polyphony) {
        voices = [SynthVoice](repeating: SynthVoice(), count: Swift.max(polyphony, 1))
    }

    public var activeVoices: Int { voices.count { $0.isActive } }

    /// Start a note. Returns a tag the caller can use to release it.
    @discardableResult
    public mutating func noteOn(frequency: Double, velocity: Double, spec: RenderVoiceSpec,
                                timbre: TimbreState, sampleRate: Double,
                                residue: Int, partner: Int = -1, pan: Double = 0) -> Int {
        let tag = nextTag
        nextTag &+= 1
        var slot = voices.firstIndex { !$0.isActive }
        if slot == nil {
            // Steal the oldest, which is the one nearest to finishing. Stealing the newest
            // would cut off the note that just arrived, which is the audible one.
            slot = voices.indices.min { voices[$0].tag < voices[$1].tag }
            stolenVoices += 1
        }
        guard let index = slot else { return -1 }
        voices[index].start(frequency: frequency, velocity: velocity, spec: spec,
                            timbre: timbre, sampleRate: sampleRate,
                            tag: tag, residue: residue, partner: partner, pan: pan)
        return tag
    }

    public mutating func noteOff(tag: Int) {
        for i in voices.indices where voices[i].isActive && voices[i].tag == tag {
            voices[i].release()
        }
    }

    public mutating func allNotesOff() {
        for i in voices.indices { voices[i].silence() }
    }

    /// Which residues each sounding voice belongs to, for the spatial layer to position.
    public func residue(ofVoice index: Int) -> (residue: Int, partner: Int)? {
        guard voices.indices.contains(index), voices[index].isActive else { return nil }
        return (voices[index].residue, voices[index].partner)
    }

    /// Mix every sounding voice into a stereo pair over `range`, which is cleared first.
    public mutating func render(left: UnsafeMutableBufferPointer<Float>,
                                right: UnsafeMutableBufferPointer<Float>,
                                range: Range<Int>, sampleRate: Double) {
        for i in range { left[i] = 0; right[i] = 0 }
        for i in voices.indices where voices[i].isActive {
            voices[i].render(left: left, right: right, range: range, sampleRate: sampleRate)
        }
    }
}
