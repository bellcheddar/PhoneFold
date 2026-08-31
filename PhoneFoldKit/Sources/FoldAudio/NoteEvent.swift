import Foundation
import FoldCore

/// One note the score asks for, and where in the protein it comes from.
///
/// **Every note carries its residue.** That is not decoration: PLAN.md's audio architecture
/// puts each note at that residue's live 3D coordinate through `AVAudioEnvironmentNode`, so the
/// fold collapses around the listener. A note that did not know which residue produced it could
/// not be placed, and spatial audio is built in from the start rather than added later.
public struct NoteEvent: Sendable, Hashable {
    public let voice: Voice
    public let note: MIDINote
    /// The residue this note comes from, and is positioned at.
    public let residue: Int
    /// For a contact, the other partner. A contact happens *between* two residues, so the
    /// spatial layer places it at their midpoint rather than at either end.
    public let partner: Int?
    /// Where in the bar this note falls, in beats from the moment's downbeat.
    public let beatOffset: Double
    /// How long it sounds, in beats.
    public let duration: Double
    /// Which fold this note belongs to, in a duet. `.solo` for every ordinary piece.
    public let part: DuetPart

    public init(voice: Voice, note: MIDINote, residue: Int, partner: Int? = nil,
                beatOffset: Double = 0, duration: Double = 1, part: DuetPart = .solo) {
        self.voice = voice
        self.note = note
        self.residue = residue
        self.partner = partner
        self.beatOffset = beatOffset
        self.duration = duration
        self.part = part
    }

    /// The residues whose coordinates place this note. One for a texture note, two for a
    /// contact, and the spatial layer averages them.
    public var spatialResidues: [Int] {
        if let partner { [residue, partner] } else { [residue] }
    }
}

/// The continuous parameters mean confidence drives.
///
/// PLAN.md: "Mean pLDDT - low-pass cutoff, detune, reverb wet mix. Low confidence sounds murky
/// and out of tune." All three move together, which is what makes the effect legible: a
/// well-resolved structure is bright, dry and in tune, and a disordered one is none of those.
public struct TimbreState: Sendable, Hashable {
    /// Low-pass corner in hertz.
    public let cutoff: Double
    /// Cents of detune *added to* each voice's own, so a style can be built out of tune on
    /// purpose and still get murkier when confidence falls.
    public let detuneCents: Double
    /// Reverb wet fraction, 0...1.
    public let reverb: Double

    public init(cutoff: Double, detuneCents: Double, reverb: Double) {
        self.cutoff = cutoff
        self.detuneCents = detuneCents
        self.reverb = reverb
    }
}

/// Everything one raw frame of the trajectory asks the music to do.
///
/// Produced only for raw frames. Interpolated frames exist for the renderer's 60 fps and are
/// not musical events - PLAN.md is explicit that triggering on them turns one contact into a
/// machine-gun burst.
public struct ScoreMoment: Sendable, Hashable {
    public let frameIndex: Int
    /// Beats per minute this moment plays at.
    public let tempo: Double
    /// How much musical time this moment occupies.
    ///
    /// Usually one beat per raw readout. A very short trajectory gets more, so that eight
    /// ESMFold readouts still amount to a phrase rather than two seconds - see
    /// `Sonifier.beatsPerMoment(forReadouts:)`.
    public let beats: Double
    public let notes: [NoteEvent]
    public let timbre: TimbreState
    /// The scale degree the harmony currently sits on.
    public let degree: Int
    /// True on the frame the structure first converges: the cadence back to the tonic.
    public let isCadence: Bool
    /// True on a recycle boundary: the harmonic modulation.
    public let isModulation: Bool
    /// How compact the chain is, 0 fully unfolded and 1 fully folded.
    public let compaction: Double
    /// Contacts that formed on this frame but were not sounded, because more formed at once
    /// than a bar can carry. Reported rather than dropped silently, so a trajectory that is
    /// losing most of its events says so instead of just sounding thin.
    public let droppedContacts: Int
    /// Contacts that were already present when the trajectory began, on its first frame.
    ///
    /// Distinct from dropped: nothing went wrong. A trajectory starts in some state, and that
    /// state's contacts are inventory rather than events.
    public let establishedContacts: Int

    public init(frameIndex: Int, tempo: Double, notes: [NoteEvent], timbre: TimbreState,
                degree: Int, isCadence: Bool, isModulation: Bool, compaction: Double,
                droppedContacts: Int, establishedContacts: Int = 0,
                beats: Double = Sonifier.beatsPerMoment) {
        self.frameIndex = frameIndex
        self.tempo = tempo
        self.beats = Swift.max(beats, 0.05)
        self.notes = notes
        self.timbre = timbre
        self.degree = degree
        self.isCadence = isCadence
        self.isModulation = isModulation
        self.compaction = compaction
        self.droppedContacts = droppedContacts
        self.establishedContacts = establishedContacts
    }
}

/// The pitch layer: which note a residue *is*, before the trajectory does anything to it.
///
/// PLAN.md asks for the Tay et al. Fantasy-Impromptu approach (Heliyon 2021, 7(9):e07933,
/// doi:10.1016/j.heliyon.2021.e07933) as the pitch layer beneath the trajectory events: an
/// amino acid property mapping, with R, K, D and E as octave-shift triggers.
///
/// The property used here is Kyte-Doolittle hydropathy, which `AminoAcid` already carries and
/// which the contact classifier already uses. Residues are ranked by it and the rank taken
/// modulo the scale, so residues of similar character sit on adjacent degrees and a run of
/// like residues moves stepwise rather than leaping - the thing that makes a mapping sound
/// like a melody instead of a lookup table.
public struct PitchLayer: Sendable, Hashable {
    public let scale: MusicalScale
    /// One-letter codes whose appearance shifts the note up an octave.
    public let octaveShiftResidues: Set<Character>

    public init(scale: MusicalScale, octaveShiftResidues: Set<Character> = []) {
        self.scale = scale
        self.octaveShiftResidues = octaveShiftResidues
    }

    public init(style: StyleProfile) {
        self.init(scale: style.scale,
                  octaveShiftResidues: Set(style.octaveShiftResidues.compactMap(\.first)))
    }

    /// The twenty acids ordered most to least hydrophobic, ties broken by one-letter code so
    /// the order is fixed. `unknown` is excluded: it is not an amino acid and is given the
    /// tonic rather than a rank of its own.
    static let hydropathyOrder: [AminoAcid] = AminoAcid.allCases
        .filter { $0 != .unknown }
        .sorted {
            $0.hydropathy != $1.hydropathy
                ? $0.hydropathy > $1.hydropathy
                : $0.rawValue < $1.rawValue
        }

    static let degrees: [AminoAcid: Int] = {
        var map: [AminoAcid: Int] = [:]
        for (rank, acid) in hydropathyOrder.enumerated() { map[acid] = rank % 7 }
        map[.unknown] = 0
        return map
    }()

    public func degree(for acid: AminoAcid) -> Int { Self.degrees[acid] ?? 0 }

    /// The pitch for a residue, in a given octave relative to the scale's own.
    public func pitch(for acid: AminoAcid, octave: Int) -> UInt8 {
        let shift = octaveShiftResidues.contains(acid.code) ? 1 : 0
        return scale.pitch(degree: degree(for: acid), octaveShift: octave + shift)
    }
}
