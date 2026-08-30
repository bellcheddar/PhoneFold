import Foundation

/// Plays a score: the clock, the voice pool and the note-offs, in one thing that can be driven
/// from an audio render callback or from an offline loop.
///
/// Written once and used both ways deliberately. The offline renderer and the live engine
/// running different scheduling code would mean the WAV Marc auditions is not the piece the
/// app plays, and the whole point of the offline path is to be able to trust it.
///
/// **Nothing here allocates once it is running.** The voice pool, the jitter buffer and the
/// scratch note list are all sized at construction. A note that arrives when every voice is
/// busy steals one; it never grows the pool.
public struct ScorePlayer: Sendable {

    /// The block the synthesiser is advanced in between checks for new notes.
    ///
    /// Onsets are quantised to this, so it bounds the timing error: 64 samples is 1.3 ms at
    /// 48 kHz, which is a tenth of what a listener can hear as early or late, and far cheaper
    /// than splitting every buffer at every note boundary.
    static let controlBlock = 64

    public let sampleRate: Double
    public let residueCount: Int
    /// Master gain before the limiter. Headroom for a full bar: sixteen contact onsets plus a
    /// pad and two texture voices is a lot of simultaneous sound.
    public var masterGain: Double

    private var synthesiser: Synthesiser
    private var clock: MusicalClock
    private let specs: [RenderVoiceSpec]
    /// Notes handed over by the clock and not yet started. Reserved once.
    private var due: [ScheduledNote]
    /// Notes currently sounding, and the sample each should be released at.
    private var sounding: [(tag: Int, endSample: Int)]
    private var soundingCount = 0
    private var sample = 0

    public init(style: StyleProfile, residueCount: Int, sampleRate: Double = 48_000,
                polyphony: Int = Synthesiser.polyphony,
                capacity: Int = MusicalClock.defaultCapacity,
                masterGain: Double = 0.5) {
        self.sampleRate = sampleRate
        self.residueCount = Swift.max(residueCount, 1)
        self.masterGain = masterGain
        synthesiser = Synthesiser(polyphony: polyphony)
        clock = MusicalClock(capacity: capacity)
        // Indexed by `Voice.slot`, so looking a timbre up on the audio thread is an array
        // subscript rather than a dictionary hash.
        var table = [RenderVoiceSpec](repeating: RenderVoiceSpec(VoiceSpec()),
                                      count: Voice.allCases.count)
        for voice in Voice.allCases { table[voice.slot] = RenderVoiceSpec(style.spec(voice)) }
        specs = table
        due = []
        due.reserveCapacity(256)
        sounding = [(tag: Int, endSample: Int)](repeating: (-1, 0), count: Swift.max(polyphony, 1))
    }

    public var starvedBeats: Int { clock.starvedBeats }
    public var refusedNotes: Int { clock.refusedNotes }
    public var activeVoices: Int { synthesiser.activeVoices }
    /// Seconds of music rendered so far.
    public var elapsed: Double { Double(sample) / sampleRate }
    /// When the next submitted moment will begin. A producer uses this to decide whether the
    /// player is ready for more, rather than pushing until it is refused.
    public var nextBeat: Double { clock.nextBeat }

    @discardableResult
    public mutating func submit(_ moment: ScoreMoment) -> Bool { clock.submit(moment) }

    public mutating func reset() {
        clock.reset()
        synthesiser.allNotesOff()
        due.removeAll(keepingCapacity: true)
        soundingCount = 0
        sample = 0
    }

    /// Where a note sits on the stage, from -1 at the N-terminus to 1 at the C-terminus.
    ///
    /// **This is the offline preview's spatialisation, and it is a projection, not the real
    /// thing.** The live engine positions every note at its residue's actual 3D coordinate
    /// through `AVAudioEnvironmentNode`, which is what makes the fold collapse around the
    /// listener. Panning by sequence position gives a stereo file the same *ordering* without
    /// needing the coordinates, so a rendered preview still lays the chain out across the
    /// stage rather than piling it in the middle.
    func pan(for note: NoteEvent) -> Double {
        guard residueCount > 1 else { return 0 }
        let indices = note.spatialResidues
        guard !indices.isEmpty else { return 0 }
        var total = 0.0
        for index in indices { total += Double(index) }
        let mean = total / Double(indices.count)
        return 2 * mean / Double(residueCount - 1) - 1
    }

    /// Bounded above 0.95 so a dense bar cannot hard-clip.
    ///
    /// Transparent below the knee - most of the piece never reaches it - and asymptotic above,
    /// so the output is strictly inside -1...1 whatever the voice count does. PLAN.md's gate
    /// asks for an offline render with no clipping, and a limiter that guarantees it is a
    /// better answer than a gain that happens to be low enough today.
    static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.95
        // The ceiling is 0.999, not 1. With a ceiling of exactly 1 the asymptote *reaches* it
        // in Float - 0.95 + 0.05 * tanh(large) rounds to 1.0 - so the output touched full
        // scale, which leaves nothing for the sixteen-bit conversion to round into.
        let ceiling: Float = 0.999
        guard abs(x) > knee else { return x }
        let sign: Float = x < 0 ? -1 : 1
        return sign * (knee + (ceiling - knee) * tanh((abs(x) - knee) / (ceiling - knee)))
    }

    private mutating func startDueNotes() {
        let now = Double(sample) / sampleRate
        clock.advance(to: now, into: &due)
        for scheduled in due {
            let note = scheduled.note
            let tag = synthesiser.noteOn(
                frequency: note.note.frequency,
                velocity: Double(note.note.velocity) / 127,
                spec: specs[note.voice.slot],
                timbre: scheduled.timbre,
                sampleRate: sampleRate,
                residue: note.residue,
                partner: note.partner ?? -1,
                pan: pan(for: note))
            guard tag >= 0 else { continue }
            let end = sample + Int(Swift.max(scheduled.duration, 0.01) * sampleRate)
            if soundingCount < sounding.count {
                sounding[soundingCount] = (tag, end)
                soundingCount += 1
            } else {
                // Every slot is tracked already, which means the pool is stealing anyway. The
                // note still sounds; it just runs to the end of its envelope rather than being
                // released on time.
                synthesiser.noteOff(tag: sounding[0].tag)
                sounding[0] = (tag, end)
            }
        }
        due.removeAll(keepingCapacity: true)
    }

    private mutating func releaseFinishedNotes() {
        var index = 0
        while index < soundingCount {
            if sounding[index].endSample <= sample {
                synthesiser.noteOff(tag: sounding[index].tag)
                soundingCount -= 1
                sounding[index] = sounding[soundingCount]
            } else {
                index += 1
            }
        }
    }

    /// Render one buffer of stereo audio. The buffers are written, not added to.
    public mutating func render(left: UnsafeMutableBufferPointer<Float>,
                                right: UnsafeMutableBufferPointer<Float>) {
        let frames = Swift.min(left.count, right.count)
        var offset = 0
        while offset < frames {
            releaseFinishedNotes()
            startDueNotes()
            let end = Swift.min(offset + Self.controlBlock, frames)
            synthesiser.render(left: left, right: right, range: offset..<end,
                               sampleRate: sampleRate)
            for i in offset..<end {
                left[i] = Self.softClip(left[i] * Float(masterGain))
                right[i] = Self.softClip(right[i] * Float(masterGain))
            }
            sample += end - offset
            offset = end
        }
    }
}

extension Voice {
    /// A dense index, so a per-voice table is an array rather than a dictionary. Written out
    /// rather than derived from `allCases`, which would allocate on every lookup.
    public var slot: Int {
        switch self {
        case .contact: 0
        case .pad: 1
        case .rhythm: 2
        case .arpeggio: 3
        case .bass: 4
        }
    }
}
