import Foundation
import FoldCore

/// A note, in the only terms the whole audio path needs: a MIDI pitch and how hard it is struck.
///
/// Deliberately not a frequency. Every style profile is written in scale degrees, every voicing
/// rule is written in semitones, and the MIDI export in PLAN.md Phase 3 has to round-trip - all
/// of which are integer arithmetic on pitch numbers. Converting to hertz is the synthesiser's
/// job and happens once, at the very end.
public struct MIDINote: Sendable, Hashable {
    /// 0...127, where 60 is middle C.
    public let pitch: UInt8
    /// 1...127. Zero would be a note-off, which this type does not represent.
    public let velocity: UInt8

    public init(pitch: UInt8, velocity: UInt8) {
        self.pitch = Swift.min(pitch, 127)
        self.velocity = Swift.min(Swift.max(velocity, 1), 127)
    }

    /// Concert pitch, for a synthesiser that wants hertz. A' = 440 Hz at MIDI 69.
    public var frequency: Double { 440 * pow(2, (Double(pitch) - 69) / 12) }
}

/// The modes PLAN.md's five styles are written in.
///
/// Stored as semitone offsets from the root rather than as names, because everything downstream
/// asks "what is the fourth degree of this scale" and never "is this Dorian".
public enum MusicalMode: String, Sendable, Codable, CaseIterable {
    case major, minor, dorian, mixolydian, aeolian, phrygian

    /// Semitones above the root for each degree of the scale.
    public var intervals: [Int] {
        switch self {
        case .major:      [0, 2, 4, 5, 7, 9, 11]
        case .minor:      [0, 2, 3, 5, 7, 8, 10]
        // Aeolian *is* the natural minor. Both names are kept because PLAN.md names Rock as
        // Aeolian and Fantasy as minor, and a style file should be able to say what it means.
        case .aeolian:    [0, 2, 3, 5, 7, 8, 10]
        case .dorian:     [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        case .phrygian:   [0, 1, 3, 5, 7, 8, 10]
        }
    }
}

/// A key: a root note and a mode, and the arithmetic for finding notes in it.
public struct MusicalScale: Sendable, Hashable {
    /// MIDI pitch of the tonic, in the octave the scale is written from.
    public let root: UInt8
    public let mode: MusicalMode

    public init(root: UInt8 = 57, mode: MusicalMode = .minor) {
        self.root = root
        self.mode = mode
    }

    /// The pitch of a scale degree, where 0 is the tonic.
    ///
    /// Degrees run past the ends of the scale in both directions: degree 7 is the tonic an
    /// octave up and degree -1 is the seventh below. That matters because the trajectory drives
    /// register directly - a long-range contact asks for a note far below the tonic - and a
    /// mapping that clamped at the octave would flatten exactly the contrast it is meant to
    /// show.
    public func pitch(degree: Int, octaveShift: Int = 0) -> UInt8 {
        let steps = mode.intervals.count
        // Floor division, so degree -1 lands on the seventh of the octave below rather than on
        // the tonic. Swift's `/` and `%` truncate toward zero, which for negatives is wrong here.
        var octave = Int(floor(Double(degree) / Double(steps)))
        var index = degree - octave * steps
        if index < 0 { index += steps; octave -= 1 }
        let semitones = Int(root) + mode.intervals[index] + 12 * (octave + octaveShift)
        return UInt8(Swift.min(Swift.max(semitones, 0), 127))
    }

    /// The nearest scale degree at or below a chromatic pitch, for snapping a free choice into
    /// the key rather than letting it sound accidental.
    public func snap(_ pitch: UInt8) -> UInt8 {
        let semitone = (Int(pitch) - Int(root)) % 12
        let normalised = semitone < 0 ? semitone + 12 : semitone
        let below = mode.intervals.last { $0 <= normalised } ?? 0
        return UInt8(Swift.min(Swift.max(Int(pitch) - (normalised - below), 0), 127))
    }
}

/// The seed that makes a protein always sound like itself.
///
/// PLAN.md Phase 3: "Seed all stochastic musical choices from a stable hash of the sequence.
/// **The same protein always yields the same piece.**"
///
/// **Not `Hasher`.** Swift's standard hashing is randomly seeded per process, by design, so a
/// piece built on it would be different every launch - which is the one thing this must never
/// be. This is FNV-1a: fixed, specified, and identical on every machine and every run.
public struct SequenceSeed: Sendable, Hashable {
    public let value: UInt64

    public init(sequence: String) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sequence.uppercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // A protein with no sequence still needs a seed, and zero is a poor one: it makes the
        // generator's first outputs degenerate.
        value = hash == 0 ? 0x9e3779b97f4a7c15 : hash
    }

    public init(value: UInt64) { self.value = value }

    /// A generator that starts from this seed, for one deterministic musical decision stream.
    public func generator() -> SplitMix64Music { SplitMix64Music(seed: value) }

    /// A generator for one *position* in the trajectory.
    ///
    /// Not the same as advancing a single stream frame by frame. A single stream makes every
    /// choice depend on how many frames came before it, so scrubbing to frame 400 would
    /// produce a different chord than playing to frame 400 - the same protein sounding like
    /// two different pieces depending on how it was reached. Deriving the stream from the
    /// position makes the score seekable, which the scrubber needs and the loop tests.
    public func stream(at position: Int) -> SplitMix64Music {
        SplitMix64Music(seed: value ^ (UInt64(bitPattern: Int64(position))
                                       &* 0x9E3779B97F4A7C15))
    }
}

/// The generator behind every stochastic musical choice.
///
/// Kept in this module rather than shared with `FoldEngine`'s: the two must be able to change
/// independently. Reseeding the physics must never alter the music, and a change to a musical
/// decision must never move a fold.
public struct SplitMix64Music: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
        for _ in 0..<8 { _ = next() }
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0 up to but not including 1.
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// A choice from a collection, deterministic for a given seed.
    public mutating func pick<T>(_ options: [T]) -> T? {
        guard !options.isEmpty else { return nil }
        return options[Int(uniform() * Double(options.count)) % options.count]
    }
}
