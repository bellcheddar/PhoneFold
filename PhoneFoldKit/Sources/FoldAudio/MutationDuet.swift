import Foundation
import FoldCore

/// Which of the two folds a note belongs to.
///
/// A note carries this so the MIDI export can put the two on separate channels, the spatial
/// mix can place them apart, and a listener can tell which protein is which.
public enum DuetPart: String, Sendable, Hashable, Codable, CaseIterable {
    /// A single fold, which is every piece that is not a duet.
    case solo
    case wildType
    case mutant

    /// MIDI channels 0-4 for the wild type, 5-9 for the mutant. Channel 9 is General MIDI's
    /// drum channel, so the mutant's voices are offset past it rather than through it.
    public var channelOffset: UInt8 {
        switch self {
        case .solo, .wildType: 0
        case .mutant: 10
        }
    }
}

/// Two folds, played together.
///
/// PLAN.md Phase 4: "Mutation duet: fold wild type and mutant in the same key, two channels,
/// pLDDT delta driving dissonance. This is the feature that gets it used by protein engineers
/// rather than admired."
///
/// **What "dissonance" means here is a decision, not a knob.** The two parts are in the same
/// key by construction - the same style, the same root, the same pacing - so the interval
/// *between* them is the whole effect. Where the two folds agree about how well a residue is
/// doing, the mutant sings the wild type's note and the two are in unison. Where they disagree,
/// the mutant's note is displaced along a ladder of intervals ordered by consonance, so a
/// region the mutation has wrecked arrives as a minor second or a tritone against an otherwise
/// untouched piece.
///
/// The ordering is the conventional Western one - unison, octave, fifth, fourth, major sixth,
/// major third, minor third, minor sixth, major second, minor seventh, major seventh, minor
/// second, tritone. It is a convention rather than an acoustic law, and it is written here so
/// that it can be argued with rather than being buried in a lookup.
public enum MutationDuet {

    /// Semitone intervals, most consonant first.
    public static let consonanceLadder: [Int] = [0, 12, 7, 5, 9, 4, 3, 8, 2, 10, 11, 1, 6]

    /// The confidence difference, in points, at which the two parts are as far apart as they go.
    ///
    /// Thirty on the 0-100 scale. A pLDDT difference of thirty between the same residue in two
    /// folds is not a rounding difference, it is one model being confident where the other is
    /// not - which is exactly the residue an engineer is looking for. Beyond that the interval
    /// is already a tritone and there is nowhere further to go.
    public static let fullDivergence: Float = 30

    /// One score plus the per-residue confidence behind each of its moments.
    public struct Part: Sendable {
        public var moments: [ScoreMoment]
        /// Per moment, the confidence of every residue at that moment.
        public var confidence: [[Float]]

        public init(moments: [ScoreMoment], confidence: [[Float]]) {
            self.moments = moments
            self.confidence = confidence
        }

        /// Build a part from a scored trajectory, keeping each moment beside its frame.
        public static func make(style: StyleProfile, residues: [AminoAcid],
                                frames: [FoldFrame],
                                targetSeconds: Double = Sonifier.targetSeconds) -> Part {
            let readouts = frames.count { !$0.isInterpolated }
            let pacing = Sonifier.pacing(readouts: readouts, style: style,
                                         targetSeconds: targetSeconds)
            var sonifier = Sonifier(style: style, residues: residues,
                                    beatsPerMoment: pacing.beatsPerMoment,
                                    readoutsPerMoment: pacing.readoutsPerMoment)
            var moments: [ScoreMoment] = []
            var confidence: [[Float]] = []
            for frame in frames {
                guard let moment = sonifier.moment(for: frame) else { continue }
                moments.append(moment)
                confidence.append(frame.pLDDT)
            }
            return Part(moments: moments, confidence: confidence)
        }
    }

    /// How far apart two parts are at one residue, 0 to 1.
    public static func divergence(_ a: Float, _ b: Float) -> Double {
        guard a.isFinite, b.isFinite else { return 0 }
        return Swift.min(Double(abs(a - b)) / Double(fullDivergence), 1)
    }

    /// The interval the mutant sings against the wild type, in semitones.
    public static func interval(divergence d: Double) -> Int {
        let clamped = Swift.min(Swift.max(d, 0), 1)
        // The ladder's *last* entry is the harshest, so a divergence of 1 lands on the tritone.
        let index = Int((clamped * Double(consonanceLadder.count - 1)).rounded())
        return consonanceLadder[Swift.min(index, consonanceLadder.count - 1)]
    }

    /// Play the two folds together as one score.
    ///
    /// The parts are zipped moment for moment. They are the same length by construction - the
    /// same pacing rule over the same number of readouts - but a mismatch is truncated rather
    /// than padded, because a duet whose second half is a solo is not a duet and should be
    /// visibly shorter rather than quietly half-empty.
    public static func merge(wildType: Part, mutant: Part) -> [ScoreMoment] {
        let count = Swift.min(wildType.moments.count, mutant.moments.count)
        guard count > 0 else { return [] }

        var merged: [ScoreMoment] = []
        merged.reserveCapacity(count)
        for index in 0..<count {
            let wild = wildType.moments[index]
            let mutantMoment = mutant.moments[index]
            let wildConfidence = index < wildType.confidence.count
                ? wildType.confidence[index] : []
            let mutantConfidence = index < mutant.confidence.count
                ? mutant.confidence[index] : []

            var notes = wild.notes.map { $0.assigned(to: .wildType) }
            for note in mutantMoment.notes {
                let residue = note.residue
                let a = residue < wildConfidence.count ? wildConfidence[residue] : 0
                let b = residue < mutantConfidence.count ? mutantConfidence[residue] : 0
                let semitones = interval(divergence: divergence(a, b))
                notes.append(note.assigned(to: .mutant).transposed(by: semitones))
            }
            notes.sort {
                if $0.beatOffset != $1.beatOffset { return $0.beatOffset < $1.beatOffset }
                if $0.part != $1.part { return $0.part.rawValue < $1.part.rawValue }
                if $0.voice != $1.voice { return $0.voice.rawValue < $1.voice.rawValue }
                return $0.note.pitch < $1.note.pitch
            }

            // The wild type keeps the harmony: it is the reference, and a duet whose tonality
            // is decided by the mutant would be reading the answer off the thing under test.
            merged.append(ScoreMoment(
                frameIndex: wild.frameIndex, tempo: wild.tempo, notes: notes,
                timbre: wild.timbre, degree: wild.degree, isCadence: wild.isCadence,
                isModulation: wild.isModulation, compaction: wild.compaction,
                droppedContacts: wild.droppedContacts + mutantMoment.droppedContacts,
                establishedContacts: wild.establishedContacts
                    + mutantMoment.establishedContacts,
                beats: wild.beats))
        }
        return merged
    }

    /// The residues where the two folds disagree most, for the readout.
    ///
    /// What an engineer actually wants out of this: not "it sounded wrong" but *where*.
    public static func divergentResidues(wildType: Part, mutant: Part,
                                         limit: Int = 8) -> [(residue: Int, delta: Float)] {
        guard let a = wildType.confidence.last, let b = mutant.confidence.last else { return [] }
        let count = Swift.min(a.count, b.count)
        var deltas: [(residue: Int, delta: Float)] = []
        for i in 0..<count where a[i].isFinite && b[i].isFinite {
            deltas.append((i, a[i] - b[i]))
        }
        // By magnitude, but the sign is kept: a mutation that *raises* confidence somewhere is
        // as interesting as one that lowers it, and reporting only the drops would hide it.
        return Array(deltas.sorted { abs($0.delta) > abs($1.delta) }.prefix(limit))
    }
}

extension NoteEvent {
    /// The same note, belonging to one part of a duet.
    public func assigned(to part: DuetPart) -> NoteEvent {
        NoteEvent(voice: voice, note: note, residue: residue, partner: partner,
                  beatOffset: beatOffset, duration: duration, part: part)
    }

    /// The same note, moved by a number of semitones.
    public func transposed(by semitones: Int) -> NoteEvent {
        let pitch = Swift.min(Swift.max(Int(note.pitch) + semitones, 0), 127)
        return NoteEvent(voice: voice,
                         note: MIDINote(pitch: UInt8(pitch), velocity: note.velocity),
                         residue: residue, partner: partner, beatOffset: beatOffset,
                         duration: duration, part: part)
    }
}
