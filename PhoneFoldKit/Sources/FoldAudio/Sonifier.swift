import Foundation
import FoldCore

/// Turns a folding trajectory into music.
///
/// This is PLAN.md's core table, implemented row for row. The whole competitive argument of the
/// app is that the music comes from the *trajectory* and not from the sequence, so the mapping
/// has to be defensible and audible:
///
/// | Trajectory feature | Musical parameter | Where |
/// |---|---|---|
/// | New contact event | Note onset; separation sets register | `contactNotes` |
/// | Long-range hydrophobic contact | Bass note | `contactNotes` |
/// | Helix content | Sustained pad, stacked fourths | `padNotes` |
/// | Sheet content | Staccato interlocking figure | `rhythmNotes` |
/// | Coil content | Arpeggiation between chord tones | `arpeggioNotes` |
/// | Mean confidence | Low-pass cutoff, detune, reverb | `timbre(for:)` |
/// | Per-residue confidence | Note velocity for that residue | `velocity(at:in:)` |
/// | Radius of gyration | Tempo and register | `compaction(radiusOfGyration:residueCount:)` |
/// | Recycle boundary | Harmonic modulation | `moment(for:)` |
/// | Convergence | Cadence, resolving to the tonic | `PlateauDetector` |
///
/// **What "confidence" means depends on the engine, and this is honest about it.** For a
/// predicted trajectory it is pLDDT; for the structure-based model it is the fraction of native
/// contacts a residue has formed; for Genie 2 it is denoising progress; for a morph it is a
/// global ramp with no per-residue meaning at all. The first three carry real per-residue
/// information and the murky-and-out-of-tune effect means something. A morph's does not vary
/// between residues, so its velocities are flat by construction - not a defect, but not a
/// reading of a structure either, and the app says which engine produced a piece.
///
/// The consequence PLAN.md wants in the app copy follows directly: **an intrinsically
/// disordered region never resolves, so it stays a detuned wash for the whole piece.**
public struct Sonifier: Sendable {

    // MARK: - Constants

    /// Beats in a bar. Only the pad's length and the held-beat duration are written in bars.
    public static let beatsPerBar = 4.0

    /// How much musical time one raw readout occupies.
    ///
    /// **One beat, not one bar, and that is measured rather than chosen for tidiness.** A live
    /// fold is 180 raw readouts. At one bar each, the Fantasy style's 66 to 132 BPM makes an
    /// eight-minute piece over an animation the app plays in twelve seconds - rendered and
    /// timed, not estimated. At one beat each it is 180 beats, 82 to 164 seconds, which is a
    /// piece of music and can share a clock with a fold the viewer is willing to watch.
    ///
    /// The gallery's eight-readout references become eight beats, which is short. They contain
    /// eight ESMFold readouts of an already-folded protein, so there is not more music in them
    /// to find.
    public static let beatsPerMoment = 1.0

    /// The gap between contacts in a flurry, in beats. Semiquavers.
    ///
    /// A beat's worth of contacts can run past its own beat and overlap the moments after it,
    /// which is why the clock schedules on an absolute timeline rather than a bar at a time.
    /// Sixteen contacts is a four-beat run - a gesture - where sixteen crammed into one beat
    /// would be the machine-gun burst PLAN.md warns about.
    static let contactSpacing = 0.25

    /// The most contacts that can sound in one bar.
    ///
    /// **Measured, not guessed.** Across the three engines, excluding each trajectory's first
    /// readout, contacts per readout run: structure-based p90 = 6 to 16 and p99 = 10 to 24
    /// (trp-cage, villin HP36 and ubiquitin at 200k steps); morph p90 = 2 to 6, max 13. Sixteen
    /// therefore leaves better than nine bars in ten whole, and spread across four beats it is
    /// a run of semiquavers rather than a cluster. Overflow is counted into
    /// `ScoreMoment.droppedContacts` rather than discarded quietly.
    static let maximumContactNotes = 16

    /// The most notes a texture voice may place in one moment. Four to a beat is semiquavers,
    /// which is as fast as the arpeggio can articulate at the style's top tempo.
    static let maximumTextureNotes = 4

    /// Octave offsets, relative to the style's own root octave.
    ///
    /// PLAN.md: "Sequence separation sets register: local high, long-range low."
    static func octave(for range: ContactRange) -> Int {
        switch range {
        case .local: 1
        case .medium: 0
        case .longRange: -1
        }
    }
    /// Long-range hydrophobic contacts are core packing, and go lower still.
    static let bassOctave = -2
    static let padOctave = 0
    static let rhythmOctave = 1
    static let arpeggioOctave = 1

    // MARK: - State

    public let style: StyleProfile
    public let residues: [AminoAcid]
    public let seed: SequenceSeed
    private let pitchLayer: PitchLayer

    /// Index into `style.progression`.
    private var chordIndex = 0
    private var lastRecycle: Int?
    private var hasEstablished = false
    private var plateau: PlateauDetector
    private var hasCadenced = false

    public init(style: StyleProfile, residues: [AminoAcid], seed: SequenceSeed? = nil,
                plateau: PlateauDetector = PlateauDetector()) {
        self.style = style
        self.residues = residues
        self.seed = seed ?? SequenceSeed(sequence: String(residues.map(\.code)))
        self.pitchLayer = PitchLayer(style: style)
        self.plateau = plateau
    }

    // MARK: - The mapping

    /// The music for one frame, or nil if the frame is not a musical event.
    ///
    /// Interpolated frames return nil. They exist so the renderer can run at 60 fps between raw
    /// readouts; triggering on them would turn one contact into a burst of sixty.
    public mutating func moment(for frame: FoldFrame) -> ScoreMoment? {
        guard !frame.isInterpolated, frame.residueCount > 0 else { return nil }

        // Harmony. A recycle boundary modulates; convergence cadences and then stays put,
        // because a piece that resolves and then wanders off has not resolved.
        var isModulation = false
        if let last = lastRecycle, frame.recycle != last, !hasCadenced {
            chordIndex = (chordIndex + 1) % style.progression.count
            isModulation = true
        }
        lastRecycle = frame.recycle

        var isCadence = false
        if plateau.update(frame.meanPLDDT) {
            if !hasCadenced { isCadence = true; hasCadenced = true }
            chordIndex = style.progression.count - 1
        }
        let degree = style.progression[chordIndex]

        // Register and tempo, from how compact the chain is.
        let compaction = Self.compaction(radiusOfGyration: frame.radiusOfGyration,
                                         residueCount: frame.residueCount)
        let tempo = style.tempo(compaction: compaction)
        // A single octave of lift across the whole fold. More would put the texture off the
        // top of the pad's range by the time it converged.
        let register = compaction >= 0.5 ? 1 : 0

        // The voicing for this bar, chosen deterministically from the frame's own position so
        // that scrubbing to a frame gives the same chord as playing to it.
        var rng = seed.stream(at: frame.index)
        let voicing = rng.pick(style.voicings) ?? [0, 2, 4]
        let chordDegrees = voicing.map { degree + $0 }

        // The first raw frame is the starting state, not an event.
        //
        // Its contacts are whatever is already in contact when the trajectory begins: for a
        // structure-based fold that is the 9 to 40 local pairs of a random coil, and for a
        // bundled ESMFold readout it is the entire contact map of an already-folded protein -
        // 132 for alpha3d, 2,697 for GFP, 3,448 for alpha-synuclein. Sounding those as note
        // onsets would open every piece with a crash that says nothing about folding. They are
        // reported as established rather than dropped, because nothing went wrong.
        var established = 0
        var notes: [NoteEvent] = []
        var dropped = 0
        if hasEstablished {
            let produced = contactNotes(frame: frame, register: register)
            notes += produced.0
            dropped = produced.dropped
        } else {
            established = frame.newContacts.count
            hasEstablished = true
        }
        notes += padNotes(frame: frame, chord: chordDegrees, register: register)
        notes += rhythmNotes(frame: frame, chord: chordDegrees, register: register)
        notes += arpeggioNotes(frame: frame, chord: chordDegrees, register: register)

        // In beat order, which is the order they will be played in.
        //
        // The clock walks a bar's notes with a single watermark rather than searching, so a
        // note out of order would not be late - it would be skipped until the playhead passed
        // it, and a pad written after the contacts would never sound at all. Ties are broken
        // by voice, pitch and residue so the order is fully determined and a piece cannot
        // differ between runs by the sort alone.
        notes.sort {
            if $0.beatOffset != $1.beatOffset { return $0.beatOffset < $1.beatOffset }
            if $0.voice != $1.voice { return $0.voice.rawValue < $1.voice.rawValue }
            if $0.note.pitch != $1.note.pitch { return $0.note.pitch < $1.note.pitch }
            return $0.residue < $1.residue
        }

        return ScoreMoment(frameIndex: frame.index, tempo: tempo, notes: notes,
                           timbre: Self.timbre(meanConfidence: frame.meanPLDDT),
                           degree: degree, isCadence: isCadence, isModulation: isModulation,
                           compaction: compaction, droppedContacts: dropped,
                           establishedContacts: established)
    }

    /// Every moment in a trajectory, for offline rendering and for the tests.
    public static func score(style: StyleProfile, residues: [AminoAcid],
                             frames: [FoldFrame]) -> [ScoreMoment] {
        var sonifier = Sonifier(style: style, residues: residues)
        return frames.compactMap { sonifier.moment(for: $0) }
    }

    // MARK: - Contacts

    /// Note onsets for the contacts that formed on this frame.
    func contactNotes(frame: FoldFrame, register: Int) -> ([NoteEvent], dropped: Int) {
        // Ordered so that if the bar cannot hold them all, what survives is what carries the
        // fold: core packing first, then the longest-range contacts. Fully deterministic -
        // the indices break every tie.
        let ordered = frame.newContacts.sorted { a, b in
            let aCore = a.isHydrophobicPair && a.range == .longRange
            let bCore = b.isHydrophobicPair && b.range == .longRange
            if aCore != bCore { return aCore }
            if a.separation != b.separation { return a.separation > b.separation }
            if a.i != b.i { return a.i < b.i }
            return a.j < b.j
        }
        let kept = Array(ordered.prefix(Self.maximumContactNotes))
        // A run of semiquavers rather than a stack on the downbeat. A single contact still
        // lands on the beat; a flurry of sixteen becomes a four-beat run, which is audible as
        // sixteen events where a sixteen-note cluster is audible as one noise.
        let step = Self.contactSpacing
        let notes = kept.enumerated().map { position, contact -> NoteEvent in
            let core = contact.isHydrophobicPair && contact.range == .longRange
            let voice: Voice = core ? .bass : .contact
            let octave = (core ? Self.bassOctave : Self.octave(for: contact.range)) + register
            let acid = residue(at: contact.i)
            // The event belongs to both partners, so its velocity is their mean confidence
            // rather than one end's.
            let confidence = (Self.confidence(at: contact.i, in: frame)
                              + Self.confidence(at: contact.j, in: frame)) / 2
            return NoteEvent(voice: voice,
                             note: MIDINote(pitch: pitchLayer.pitch(for: acid, octave: octave),
                                            velocity: Self.velocity(confidence: confidence)),
                             residue: contact.i, partner: contact.j,
                             beatOffset: Double(position) * step, duration: core ? 2 : 1)
        }
        return (notes, dropped: ordered.count - kept.count)
    }

    // MARK: - Texture

    /// Helix content: a sustained chord, held for the whole bar.
    func padNotes(frame: FoldFrame, chord: [Int], register: Int) -> [NoteEvent] {
        let helix = Self.residues(frame: frame, in: .helix)
        guard !helix.isEmpty else { return [] }
        let placed = Self.spread(helix, count: chord.count)
        return zip(chord, placed).map { degree, residueIndex in
            NoteEvent(voice: .pad,
                      note: MIDINote(pitch: style.scale.pitch(degree: degree,
                                                              octaveShift: Self.padOctave + register),
                                     velocity: Self.velocity(
                                        confidence: Self.confidence(at: residueIndex, in: frame))),
                      residue: residueIndex, beatOffset: 0, duration: Self.beatsPerBar)
        }
    }

    /// Sheet content: a staccato figure, evenly across the bar.
    func rhythmNotes(frame: FoldFrame, chord: [Int], register: Int) -> [NoteEvent] {
        let sheet = Self.residues(frame: frame, in: .sheet)
        let count = Self.textureCount(fraction: frame.structureFractions.sheet)
        guard count > 0, !sheet.isEmpty else { return [] }
        let placed = Self.spread(sheet, count: count)
        let step = Self.beatsPerMoment / Double(count)
        return placed.enumerated().map { position, residueIndex in
            NoteEvent(voice: .rhythm,
                      note: MIDINote(pitch: style.scale.pitch(degree: chord[position % chord.count],
                                                              octaveShift: Self.rhythmOctave + register),
                                     velocity: Self.velocity(
                                        confidence: Self.confidence(at: residueIndex, in: frame))),
                      residue: residueIndex,
                      beatOffset: Double(position) * step, duration: 0.2)
        }
    }

    /// Coil content: arpeggiation between chord tones, offset half a step from the sheet
    /// figure so the two interlock rather than double each other.
    func arpeggioNotes(frame: FoldFrame, chord: [Int], register: Int) -> [NoteEvent] {
        let coil = Self.residues(frame: frame, in: .coil)
        let count = Self.textureCount(fraction: frame.structureFractions.coil)
        guard count > 0, !coil.isEmpty else { return [] }
        let placed = Self.spread(coil, count: count)
        let step = Self.beatsPerMoment / Double(count)
        return placed.enumerated().map { position, residueIndex in
            // Climbing through the chord and on into the octave above, which is what makes it
            // figuration rather than a repeated arpeggio.
            let degree = chord[position % chord.count] + 7 * (position / chord.count)
            return NoteEvent(voice: .arpeggio,
                             note: MIDINote(pitch: style.scale.pitch(degree: degree,
                                                                     octaveShift: Self.arpeggioOctave + register),
                                            velocity: Self.velocity(
                                                confidence: Self.confidence(at: residueIndex, in: frame))),
                             residue: residueIndex,
                             beatOffset: (Double(position) + 0.5) * step, duration: 0.25)
        }
    }

    // MARK: - Helpers

    func residue(at index: Int) -> AminoAcid {
        index >= 0 && index < residues.count ? residues[index] : .unknown
    }

    static func confidence(at index: Int, in frame: FoldFrame) -> Float {
        index >= 0 && index < frame.pLDDT.count ? frame.pLDDT[index] : frame.meanPLDDT
    }

    /// Indices of the residues currently in a given secondary structure state.
    static func residues(frame: FoldFrame, in state: SecondaryStructure) -> [Int] {
        frame.secondaryStructure.enumerated().compactMap { $1.structure == state ? $0 : nil }
    }

    /// How many notes a texture voice places for a given content fraction.
    static func textureCount(fraction: Float) -> Int {
        guard fraction > 0 else { return 0 }
        let n = Int((Double(fraction) * Double(maximumTextureNotes)).rounded())
        // Any content at all sounds at least once: rounding a small fraction to zero would
        // make a two-residue strand silent, and silence reads as "no sheet" rather than
        // "a little sheet".
        return Swift.min(Swift.max(n, 1), maximumTextureNotes)
    }

    /// `count` indices spread evenly across a list, without repeating unless it is shorter
    /// than the count asked for.
    static func spread(_ indices: [Int], count: Int) -> [Int] {
        guard !indices.isEmpty, count > 0 else { return [] }
        guard indices.count > count else {
            return (0..<count).map { indices[$0 % indices.count] }
        }
        let step = Double(indices.count) / Double(count)
        return (0..<count).map { indices[Swift.min(Int(Double($0) * step), indices.count - 1)] }
    }

    /// Per-residue confidence to note velocity.
    ///
    /// Floored at 30 rather than 1: a note that is inaudible has not been played, and the
    /// point of sounding a low-confidence residue is that it is heard *and* sounds wrong.
    public static func velocity(confidence: Float) -> UInt8 {
        let q = Swift.min(Swift.max(Double(confidence) / 100, 0), 1)
        return UInt8(30 + 90 * q)
    }

    /// Mean confidence to cutoff, detune and reverb.
    ///
    /// The cutoff is exponential because pitch and brightness are perceived in ratios: a
    /// linear sweep from 300 Hz would spend most of its travel in a range that already sounds
    /// bright, and the murk would collapse into the bottom few percent.
    public static func timbre(meanConfidence: Float) -> TimbreState {
        let q = Swift.min(Swift.max(Double(meanConfidence) / 100, 0), 1)
        // The floor is 500 Hz rather than 300. A one-pole filter is only 6 dB per octave, so
        // 300 Hz does not make a note dull, it makes it absent: a fold opening at zero
        // confidence rendered at 0.001 RMS. At 500 Hz the murk is audible as murk.
        return TimbreState(cutoff: 500 * pow(28, q),      // 500 Hz murky, 14 kHz open
                           detuneCents: 35 * (1 - q),     // a third of a semitone at worst
                           reverb: 0.60 - 0.45 * q)       // a wash, drying to a room
    }

    /// How compact the chain is: 0 at the denatured radius of gyration, 1 at the native one.
    ///
    /// Both reference radii are measured scaling laws, not guesses:
    /// - denatured, `Rg = 1.927 N^0.598` (Kohn et al., PNAS 2004, 101(34):12491-12496)
    /// - native globular, `Rg = 2.2 N^0.38` (Flory scaling as fitted by Dima and Thirumalai,
    ///   J. Phys. Chem. B 2004, 108(21):6564-6570)
    ///
    /// Normalising by chain length matters: without it a 20-residue miniprotein would be
    /// reported as permanently compact and a 300-residue one as permanently extended, and the
    /// accelerando would be a property of the protein's size rather than of its folding.
    public static func compaction(radiusOfGyration rg: Float, residueCount n: Int) -> Double {
        guard n > 1, rg.isFinite, rg > 0 else { return 0 }
        let count = Double(n)
        let denatured = 1.927 * pow(count, 0.598)
        let native = 2.2 * pow(count, 0.38)
        guard denatured > native else { return 0 }
        let t = (denatured - Double(rg)) / (denatured - native)
        return Swift.min(Swift.max(t, 0), 1)
    }
}

/// Detects the confidence plateau that PLAN.md calls convergence.
///
/// A sliding window over the raw frames' mean confidence: converged when the window's whole
/// span sits inside `tolerance`. A span rather than a slope, because a trajectory that
/// oscillates around a flat mean has a slope near zero and is plainly not converged.
public struct PlateauDetector: Sendable, Hashable {
    public let window: Int
    /// On the same 0...100 scale the confidence is reported on.
    public let tolerance: Float
    /// Below this, a flat confidence means the structure never got anywhere rather than that
    /// it arrived; a piece should not cadence onto a chain that stayed a coil.
    public let floor: Float
    private var recent: [Float] = []

    /// **The window is measured against the trajectories that exist.** At six readouts the
    /// rule fires on the last bar or the one before it for every well-resolved bundled
    /// trajectory, at bar 174 of 180 for a morph, and at bar 113 to 137 of 181 for a
    /// structure-based fold - and never for GFP, alpha-synuclein or a Genie 2 run, whose
    /// confidence either sits below the floor or climbs monotonically and so never plateaus.
    /// A longer window cannot fire at all on an eight-readout trajectory; a shorter one fires
    /// on transient stalls a third of the way through a fold.
    public init(window: Int = 6, tolerance: Float = 1.5, floor: Float = 50) {
        self.window = Swift.max(window, 2)
        self.tolerance = tolerance
        self.floor = floor
    }

    public mutating func update(_ value: Float) -> Bool {
        guard value.isFinite else { return false }
        recent.append(value)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        guard recent.count == window, let low = recent.min(), let high = recent.max() else {
            return false
        }
        return high - low <= tolerance && high >= floor
    }
}
