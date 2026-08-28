import Foundation

/// How far apart in sequence the two partners of a contact are.
///
/// This is the axis the score maps to register (PLAN.md section 3, sonification table):
/// local contacts are high notes, long-range contacts are low ones. The boundaries follow
/// the usual contact-order convention.
public enum ContactRange: UInt8, CaseIterable, Sendable, Hashable {
    /// |i - j| in 3...5. Helix-turn scale.
    case local = 0
    /// |i - j| in 6...11.
    case medium = 1
    /// |i - j| >= 12. Tertiary structure. The ones that matter.
    case longRange = 2

    public init(separation: Int) {
        switch abs(separation) {
        case ..<6: self = .local
        case 6..<12: self = .medium
        default: self = .longRange
        }
    }
}

/// A CA-CA contact forming, emitted on the frame where the pair crosses the cutoff inwards.
///
/// Emitted once per formation, not once per frame while in contact: this is a note onset,
/// and a sustained contact must not retrigger. Breaking and re-forming does emit again.
public struct ContactEvent: Sendable, Hashable {
    /// Index of the lower-numbered residue, 0-based.
    public let i: Int
    /// Index of the higher-numbered residue, 0-based. Always `> i`.
    public let j: Int
    /// CA-CA distance in angstroms at the frame of formation.
    public let distance: Float
    public let range: ContactRange
    /// True when both partners are hydrophobic by Kyte-Doolittle. A long-range hydrophobic
    /// contact is core packing: the bass note and the haptic transient in Phase 3.
    public let isHydrophobicPair: Bool

    public init(i: Int, j: Int, distance: Float, isHydrophobicPair: Bool) {
        let (lo, hi) = i <= j ? (i, j) : (j, i)
        self.i = lo
        self.j = hi
        self.distance = distance
        self.range = ContactRange(separation: hi - lo)
        self.isHydrophobicPair = isHydrophobicPair
    }

    /// Sequence separation, always positive.
    public var separation: Int { j - i }
}
